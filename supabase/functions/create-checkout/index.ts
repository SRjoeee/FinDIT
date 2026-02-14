/// Create Stripe Checkout Session for Pro upgrade
///
/// Requires authenticated user with active subscription record.
/// Returns checkout_url that opens Stripe-hosted payment page.
/// Uses hardcoded success/cancel URLs (no client-supplied URLs for security).

import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { createAdminClient, getUser } from "../_shared/supabase.ts";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-12-18.acacia",
  httpClient: Stripe.createFetchHttpClient(),
});

const PRICE_ID = Deno.env.get("STRIPE_PRO_PRICE_ID")!;

// Hardcoded redirect URLs — Stripe Checkout will redirect here after payment
// Since the macOS app can't register URL schemes via SPM, we use a simple web page
// that tells the user to return to the app. The app refreshes subscription on didBecomeActive.
const SUCCESS_URL = "https://xbuyfrzfmyzrioqhnmov.supabase.co/functions/v1/checkout-result?status=success";
const CANCEL_URL = "https://xbuyfrzfmyzrioqhnmov.supabase.co/functions/v1/checkout-result?status=cancel";

Deno.serve(async (req) => {
  const corsResponse = handleCors(req);
  if (corsResponse) return corsResponse;

  try {
    const user = await getUser(req.headers.get("Authorization")!);

    const admin = createAdminClient();

    // Get subscription — check if already Pro
    const { data: sub } = await admin
      .from("subscriptions")
      .select("stripe_customer_id, plan, status")
      .eq("user_id", user.id)
      .single();

    if (sub?.plan === "pro" && sub?.status === "active") {
      return new Response(
        JSON.stringify({ error: "Already subscribed to Pro" }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // Get or create Stripe customer
    let customerId = sub?.stripe_customer_id;

    if (!customerId) {
      const customer = await stripe.customers.create({
        email: user.email,
        metadata: { supabase_user_id: user.id },
      });
      customerId = customer.id;

      await admin
        .from("subscriptions")
        .update({ stripe_customer_id: customerId })
        .eq("user_id", user.id);
    }

    // Create Checkout Session
    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: "subscription",
      line_items: [{ price: PRICE_ID, quantity: 1 }],
      success_url: SUCCESS_URL,
      cancel_url: CANCEL_URL,
      metadata: { supabase_user_id: user.id },
    });

    return new Response(
      JSON.stringify({ checkout_url: session.url }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("create-checkout error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
