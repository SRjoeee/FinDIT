/// Stripe Webhook Handler
///
/// Processes Stripe events to update subscription state:
/// - checkout.session.completed → upgrade to Pro
/// - invoice.payment_failed → mark past_due
/// - customer.subscription.deleted → downgrade to Free
///
/// Deployed with --no-verify-jwt (Stripe signs requests, not Supabase JWT).

import { createAdminClient } from "../_shared/supabase.ts";
import { updateKey } from "../_shared/openrouter.ts";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-12-18.acacia",
  httpClient: Stripe.createFetchHttpClient(),
});

const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

// Pro monthly budget in USD
const PRO_BUDGET_USD = 10.0;
const PRO_BUDGET_CENTS = 1000;

Deno.serve(async (req) => {
  const body = await req.text();
  const signature = req.headers.get("stripe-signature");

  if (!signature) {
    return new Response("Missing stripe-signature", { status: 400 });
  }

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      WEBHOOK_SECRET,
    );
  } catch (err) {
    console.error("Webhook signature verification failed:", err.message);
    return new Response(`Webhook Error: ${err.message}`, { status: 400 });
  }

  const admin = createAdminClient();
  console.log(`[stripe-webhook] Processing: ${event.type}`);

  switch (event.type) {
    case "checkout.session.completed": {
      const session = event.data.object as Stripe.Checkout.Session;
      const userId = session.metadata?.supabase_user_id;
      if (!userId) break;

      // Retrieve subscription to get current_period_end
      let periodEnd: string | null = null;
      const stripeSubId = session.subscription as string;
      if (stripeSubId) {
        try {
          const stripeSub = await stripe.subscriptions.retrieve(stripeSubId);
          periodEnd = new Date(stripeSub.current_period_end * 1000).toISOString();
        } catch (e) {
          console.error("[stripe-webhook] Failed to retrieve subscription:", e);
        }
      }

      // Update subscription to Pro
      await admin.from("subscriptions").update({
        plan: "pro",
        status: "active",
        stripe_subscription_id: stripeSubId,
        stripe_customer_id: session.customer as string,
        monthly_budget_cents: PRO_BUDGET_CENTS,
        current_period_start: new Date().toISOString(),
        current_period_end: periodEnd,
      }).eq("user_id", userId);

      // Upgrade OpenRouter key limit (non-fatal)
      const { data: keyData } = await admin
        .from("openrouter_keys")
        .select("key_hash")
        .eq("user_id", userId)
        .eq("is_active", true)
        .single();

      if (keyData?.key_hash) {
        try {
          await updateKey(keyData.key_hash, {
            limit: PRO_BUDGET_USD,
            disabled: false,
          });
          await admin
            .from("openrouter_keys")
            .update({ limit_usd: PRO_BUDGET_USD })
            .eq("user_id", userId);
        } catch (orErr) {
          console.error("[stripe-webhook] Failed to upgrade OR key:", orErr);
          // Non-fatal: subscription is already upgraded, key limit can be fixed later
        }
      }

      // Log event
      await admin.from("usage_logs").insert({
        user_id: userId,
        event_type: "upgrade_to_pro",
        details: { stripe_session_id: session.id },
      });

      console.log(`[stripe-webhook] User ${userId} upgraded to Pro`);
      break;
    }

    case "invoice.payment_failed": {
      const invoice = event.data.object as Stripe.Invoice;
      const customerId = invoice.customer as string;

      // Find user by stripe_customer_id
      const { data: sub } = await admin
        .from("subscriptions")
        .select("user_id")
        .eq("stripe_customer_id", customerId)
        .single();

      if (sub?.user_id) {
        await admin.from("subscriptions").update({
          status: "past_due",
        }).eq("user_id", sub.user_id);

        await admin.from("usage_logs").insert({
          user_id: sub.user_id,
          event_type: "payment_failed",
          details: { invoice_id: invoice.id },
        });

        console.log(`[stripe-webhook] User ${sub.user_id} payment failed → past_due`);
      }
      break;
    }

    case "customer.subscription.deleted": {
      const subscription = event.data.object as Stripe.Subscription;
      const customerId = subscription.customer as string;

      const { data: sub } = await admin
        .from("subscriptions")
        .select("user_id")
        .eq("stripe_customer_id", customerId)
        .single();

      if (sub?.user_id) {
        // Downgrade to Free
        await admin.from("subscriptions").update({
          plan: "free",
          status: "canceled",
          monthly_budget_cents: 0,
        }).eq("user_id", sub.user_id);

        // Disable OpenRouter key (non-fatal)
        const { data: keyData } = await admin
          .from("openrouter_keys")
          .select("key_hash")
          .eq("user_id", sub.user_id)
          .eq("is_active", true)
          .single();

        if (keyData?.key_hash) {
          try {
            await updateKey(keyData.key_hash, { disabled: true });
            await admin
              .from("openrouter_keys")
              .update({ is_active: false })
              .eq("user_id", sub.user_id);
          } catch (orErr) {
            console.error("[stripe-webhook] Failed to disable OR key:", orErr);
            // Non-fatal: subscription already downgraded
          }
        }

        await admin.from("usage_logs").insert({
          user_id: sub.user_id,
          event_type: "downgrade_to_free",
          details: { stripe_subscription_id: subscription.id },
        });

        console.log(`[stripe-webhook] User ${sub.user_id} downgraded to Free`);
      }
      break;
    }

    default:
      console.log(`[stripe-webhook] Unhandled event type: ${event.type}`);
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
