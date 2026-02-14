/// checkout-result: Simple landing page for Stripe redirects
///
/// Since the macOS app uses SPM (no Info.plist / URL scheme),
/// Stripe redirects to this page which tells the user to return to the app.
/// The app will auto-refresh subscription status on didBecomeActive.
///
/// Deployed with --no-verify-jwt (no auth needed for a static page).

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const status = url.searchParams.get("status") ?? "unknown";

  const isSuccess = status === "success";
  const isCancel = status === "cancel";
  const isBilling = status === "billing-return";

  let title: string;
  let message: string;
  let emoji: string;

  if (isSuccess) {
    title = "Payment Successful!";
    message = "Your FindIt Pro subscription is now active. Please return to the FindIt app — your subscription will be updated automatically.";
    emoji = "&#x2705;"; // checkmark
  } else if (isCancel) {
    title = "Payment Cancelled";
    message = "Your payment was cancelled. You can try again from FindIt Settings at any time.";
    emoji = "&#x274C;"; // cross mark
  } else if (isBilling) {
    title = "Billing Updated";
    message = "Your billing changes have been saved. Please return to the FindIt app — your subscription will be updated automatically.";
    emoji = "&#x2699;"; // gear
  } else {
    title = "FindIt";
    message = "Please return to the FindIt app.";
    emoji = "&#x1F50D;"; // magnifying glass
  }

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${title} — FindIt</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      display: flex;
      justify-content: center;
      align-items: center;
      min-height: 100vh;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      color: #333;
    }
    .card {
      background: white;
      border-radius: 16px;
      padding: 48px;
      max-width: 480px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
    }
    .emoji { font-size: 64px; margin-bottom: 24px; }
    h1 { font-size: 24px; margin-bottom: 16px; color: #1a1a1a; }
    p { font-size: 16px; line-height: 1.6; color: #666; margin-bottom: 24px; }
    .hint {
      font-size: 14px;
      color: #999;
      border-top: 1px solid #eee;
      padding-top: 16px;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="emoji">${emoji}</div>
    <h1>${title}</h1>
    <p>${message}</p>
    <p class="hint">You can close this tab and return to FindIt.</p>
  </div>
</body>
</html>`;

  return new Response(html, {
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
});
