/// check-subscription: Returns current subscription status
///
/// Called by the client on login, app launch, and periodically (1h).
/// If trial has expired, auto-downgrades to free and disables OpenRouter key.
///
/// Input: none (user from JWT)
/// Output: { plan, status, trial_ends_at, current_period_end, usage, cloud_enabled }

import { createAdminClient, getUser } from "../_shared/supabase.ts";
import { getKeyInfo, updateKey } from "../_shared/openrouter.ts";
import { corsHeaders, handleCors } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  // Handle CORS preflight
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
    const { data: sub, error: subError } = await admin
      .from("subscriptions")
      .select("*")
      .eq("user_id", user.id)
      .single();

    if (subError || !sub) {
      // No subscription found — return free plan
      return new Response(
        JSON.stringify({
          plan: "free",
          status: "active",
          trial_ends_at: null,
          current_period_end: null,
          usage: null,
          cloud_enabled: false,
        }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // Check trial expiry
    let plan = sub.plan;
    let status = sub.status;
    const now = new Date();

    if (
      plan === "trial" &&
      sub.trial_ends_at &&
      new Date(sub.trial_ends_at) < now
    ) {
      // Trial expired — downgrade to free
      plan = "free";
      status = "expired";

      await admin
        .from("subscriptions")
        .update({ plan: "free", status: "expired" })
        .eq("user_id", user.id);

      // Disable OpenRouter key
      const { data: keyRow } = await admin
        .from("openrouter_keys")
        .select("key_hash")
        .eq("user_id", user.id)
        .single();

      if (keyRow?.key_hash) {
        try {
          await updateKey(keyRow.key_hash, { disabled: true });
          await admin
            .from("openrouter_keys")
            .update({ is_active: false })
            .eq("user_id", user.id);
        } catch (e) {
          console.error("[check-subscription] Failed to disable OR key:", e);
        }
      }

      await admin.from("usage_logs").insert({
        user_id: user.id,
        event_type: "trial_expired",
        details: { trial_ends_at: sub.trial_ends_at },
      });
    }

    // Fetch OpenRouter usage if key exists
    let usage: { monthly_usd: number; limit_usd: number } | null = null;

    const { data: keyRow } = await admin
      .from("openrouter_keys")
      .select("key_hash, limit_usd, is_active")
      .eq("user_id", user.id)
      .single();

    if (keyRow?.key_hash && keyRow.is_active) {
      try {
        const info = await getKeyInfo(keyRow.key_hash);
        usage = {
          monthly_usd: info.usage_monthly ?? 0,
          limit_usd: info.limit ?? 0,
        };
      } catch (_e) {
        // OpenRouter API may be down — use cached data
        usage = {
          monthly_usd: 0,
          limit_usd: keyRow.limit_usd ?? 0,
        };
      }
    }

    const cloudEnabled =
      (plan === "trial" || plan === "pro") &&
      (status === "active" || status === "trialing");

    return new Response(
      JSON.stringify({
        plan,
        status,
        trial_ends_at: sub.trial_ends_at,
        current_period_end: sub.current_period_end,
        usage,
        cloud_enabled: cloudEnabled,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  } catch (error) {
    console.error("[check-subscription] Error:", error);
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
