/// on-user-created: Initialize new user account
///
/// Called by the client after successful sign-up.
/// Creates a trial subscription and provisions an OpenRouter API key.
///
/// Requires JWT auth (user must be authenticated).
/// Output: { openrouter_key, plan, trial_ends_at }

import { createAdminClient, getUser } from "../_shared/supabase.ts";
import { createKey } from "../_shared/openrouter.ts";
import { corsHeaders, handleCors } from "../_shared/cors.ts";

const TRIAL_DAYS = 14;
const TRIAL_BUDGET_USD = 1.0; // $1.00 monthly limit for trial

Deno.serve(async (req) => {
  // Handle CORS preflight
  const corsResponse = handleCors(req);
  if (corsResponse) return corsResponse;

  try {
    // JWT auth — extract user from token
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing auth header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const user = await getUser(authHeader);
    const userId = user.id;
    const email = user.email ?? "";

    console.log(`[on-user-created] New user: ${userId} (${email})`);

    const admin = createAdminClient();

    // Check if subscription already exists (idempotency)
    const { data: existingSub } = await admin
      .from("subscriptions")
      .select("plan")
      .eq("user_id", userId)
      .single();

    if (existingSub) {
      console.log(`[on-user-created] Subscription already exists: ${existingSub.plan}`);
      // Still need to check if key exists and return it
      const { data: existingKey } = await admin
        .from("openrouter_keys")
        .select("is_active")
        .eq("user_id", userId)
        .single();

      return new Response(
        JSON.stringify({
          openrouter_key: null, // Don't return existing key — client should use get-cloud-key
          plan: existingSub.plan,
          trial_ends_at: null,
          already_exists: true,
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const now = new Date();
    const trialEnd = new Date(now.getTime() + TRIAL_DAYS * 24 * 60 * 60 * 1000);

    // 1. Create trial subscription
    const { error: subError } = await admin.from("subscriptions").insert({
      user_id: userId,
      plan: "trial",
      status: "trialing",
      trial_started_at: now.toISOString(),
      trial_ends_at: trialEnd.toISOString(),
      monthly_budget_cents: Math.round(TRIAL_BUDGET_USD * 100),
    });

    if (subError) {
      console.error("[on-user-created] Subscription insert error:", subError);
      throw subError;
    }

    // 2. Provision OpenRouter API key
    const shortId = userId.substring(0, 8);
    let openrouterKey = "";
    let keyHash = "";
    let keyPrefix = "";

    try {
      const orResult = await createKey({
        name: `findit-${shortId}`,
        limit: TRIAL_BUDGET_USD,
        limitReset: "monthly",
      });

      openrouterKey = orResult.key;
      keyHash = orResult.data.hash;
      keyPrefix = openrouterKey.substring(0, 15) + "...";

      // 3. Store key metadata in DB (NOT the full key)
      const { error: keyError } = await admin.from("openrouter_keys").insert({
        user_id: userId,
        key_hash: keyHash,
        key_prefix: keyPrefix,
        is_active: true,
        limit_usd: TRIAL_BUDGET_USD,
      });

      if (keyError) {
        console.error("[on-user-created] Key insert error:", keyError);
        // Cleanup: try to delete the OR key we just created
        try {
          const { deleteKey } = await import("../_shared/openrouter.ts");
          await deleteKey(keyHash);
        } catch (_cleanup) {
          console.error("[on-user-created] Cleanup failed:", _cleanup);
        }
      }
    } catch (orError) {
      // OpenRouter key creation failed — user can still use local features
      console.error("[on-user-created] OpenRouter key creation failed:", orError);
    }

    // 4. Log the event
    await admin.from("usage_logs").insert({
      user_id: userId,
      event_type: "user_created",
      details: {
        plan: "trial",
        trial_days: TRIAL_DAYS,
        budget_usd: TRIAL_BUDGET_USD,
        key_provisioned: !!openrouterKey,
      },
    });

    console.log(
      `[on-user-created] Done: trial until ${trialEnd.toISOString()}, key=${!!openrouterKey}`,
    );

    return new Response(
      JSON.stringify({
        openrouter_key: openrouterKey || null,
        plan: "trial",
        trial_ends_at: trialEnd.toISOString(),
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (error) {
    console.error("[on-user-created] Error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
