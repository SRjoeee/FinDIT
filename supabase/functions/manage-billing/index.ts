/// Return Stripe Customer Portal URL for subscription management
///
/// Requires authenticated user with stripe_customer_id.
/// Portal allows users to update payment method, cancel, etc.
/// Uses hardcoded return URL for security.

import { corsHeaders, handleCors } from "../_shared/cors.ts";
import { createAdminClient, getUser } from "../_shared/supabase.ts";
import Stripe from "https://esm.sh/stripe@14?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-12-18.acacia",
  httpClient: Stripe.createFetchHttpClient(),
});

const RETURN_URL = "https://xbuyfrzfmyzrioqhnmov.supabase.co/functions/v1/checkout-result?status=billing-return";

Deno.serve(async (req) => {
  const corsResponse = handleCors(req);
  if (corsResponse) return corsResponse;

  try {
    const user = await getUser(req.headers.get("Authorization")!);

    const admin = createAdminClient();

    const { data: sub } = await admin
      .from("subscriptions")
      .select("stripe_customer_id")
      .eq("user_id", user.id)
      .single();

    if (!sub?.stripe_customer_id) {
      return new Response(
        JSON.stringify({ error: "No Stripe customer found" }),
        {
          status: 404,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const session = await stripe.billingPortal.sessions.create({
      customer: sub.stripe_customer_id,
      return_url: RETURN_URL,
    });

    return new Response(
      JSON.stringify({ portal_url: session.url }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("manage-billing error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
