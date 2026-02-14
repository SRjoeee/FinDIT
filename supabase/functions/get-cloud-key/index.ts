/// get-cloud-key: Re-provision OpenRouter key
///
/// Called when the client's Keychain doesn't have a key (reinstall, new device).
/// Also handles the case where on-user-created failed — auto-creates trial.
/// Disables the old key and creates a new one with the same budget.
///
/// Input: none (user from JWT)
/// Output: { openrouter_key, plan, usage }

import { createAdminClient, getUser } from "../_shared/supabase.ts";
import { createKey, updateKey } from "../_shared/openrouter.ts";
import { corsHeaders, handleCors } from "../_shared/cors.ts";

const TRIAL_DAYS = 14;
const TRIAL_BUDGET_USD = 1.0;

const BUDGET_BY_PLAN: Record<string, number> = {
  trial: 1.0,
  pro: 10.0,
  free: 0,
};

Deno.serve(async (req) => {
  const corsResponse = handleCors(req);
  if (corsResponse) return corsResponse;

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing auth header" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const user = await getUser(authHeader);
    const admin = createAdminClient();

    // Fetch subscription
    let { data: sub } = await admin
      .from("subscriptions")
      .select("plan, status, trial_ends_at")
      .eq("user_id", user.id)
      .single();

    // If no subscription exists (on-user-created failed), auto-create trial
    if (!sub) {
      console.log(`[get-cloud-key] No subscription found for ${user.id}, creating trial`);

      const now = new Date();
      const trialEnd = new Date(now.getTime() + TRIAL_DAYS * 24 * 60 * 60 * 1000);

      const { error: subError } = await admin.from("subscriptions").insert({
        user_id: user.id,
        plan: "trial",
        status: "trialing",
        trial_started_at: now.toISOString(),
        trial_ends_at: trialEnd.toISOString(),
        monthly_budget_cents: Math.round(TRIAL_BUDGET_USD * 100),
      });

      if (subError) {
        console.error("[get-cloud-key] Auto-create trial failed:", subError);
        return new Response(
          JSON.stringify({ error: "Failed to create subscription" }),
          {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          },
        );
      }

      sub = { plan: "trial", status: "trialing", trial_ends_at: trialEnd.toISOString() };

      await admin.from("usage_logs").insert({
        user_id: user.id,
        event_type: "trial_auto_created",
        details: { reason: "get-cloud-key fallback" },
      });
    }

    // Check if cloud is enabled
    const cloudEnabled =
      (sub.plan === "trial" || sub.plan === "pro") &&
      (sub.status === "active" || sub.status === "trialing");

    if (!cloudEnabled) {
      return new Response(
        JSON.stringify({
          error: "Cloud features not available on current plan",
          plan: sub.plan,
          status: sub.status,
        }),
        {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // Check if trial has expired
    if (sub.plan === "trial" && sub.trial_ends_at && new Date(sub.trial_ends_at) < new Date()) {
      return new Response(
        JSON.stringify({
          error: "Trial has expired",
          plan: "free",
          status: "expired",
        }),
        {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // Disable old key if exists
    const { data: oldKey } = await admin
      .from("openrouter_keys")
      .select("key_hash")
      .eq("user_id", user.id)
      .single();

    if (oldKey?.key_hash) {
      try {
        await updateKey(oldKey.key_hash, { disabled: true });
      } catch (e) {
        console.warn("[get-cloud-key] Failed to disable old key:", e);
      }
    }

    // Create new key
    const budget = BUDGET_BY_PLAN[sub.plan] ?? 1.0;
    const shortId = user.id.substring(0, 8);
    const orResult = await createKey({
      name: `findit-${shortId}`,
      limit: budget,
      limitReset: "monthly",
    });

    const keyPrefix = orResult.key.substring(0, 15) + "...";

    // Upsert key metadata
    await admin.from("openrouter_keys").upsert(
      {
        user_id: user.id,
        key_hash: orResult.data.hash,
        key_prefix: keyPrefix,
        is_active: true,
        limit_usd: budget,
      },
      { onConflict: "user_id" },
    );

    // Log
    await admin.from("usage_logs").insert({
      user_id: user.id,
      event_type: "key_rotated",
      details: { plan: sub.plan, budget_usd: budget },
    });

    console.log(`[get-cloud-key] New key for ${user.id} (${sub.plan}, $${budget})`);

    return new Response(
      JSON.stringify({
        openrouter_key: orResult.key,
        plan: sub.plan,
        usage: { monthly_usd: 0, limit_usd: budget },
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  } catch (error) {
    console.error("[get-cloud-key] Error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
