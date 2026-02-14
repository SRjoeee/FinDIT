-- FindIt SaaS Schema: profiles, subscriptions, openrouter_keys, usage_logs
-- Supabase Auth → on-user-created trigger → auto trial + OpenRouter key provisioning

-- ============================================================
-- Custom types
-- ============================================================
CREATE TYPE public.plan_type AS ENUM ('free', 'trial', 'pro');
CREATE TYPE public.subscription_status AS ENUM (
    'active', 'trialing', 'past_due', 'canceled', 'expired'
);

-- ============================================================
-- profiles: extends auth.users
-- ============================================================
CREATE TABLE public.profiles (
    id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email       TEXT,
    display_name TEXT,
    avatar_url  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own profile"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id);

-- ============================================================
-- subscriptions: tracks plan state
-- ============================================================
CREATE TABLE public.subscriptions (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                 UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    plan                    public.plan_type NOT NULL DEFAULT 'free',
    status                  public.subscription_status NOT NULL DEFAULT 'active',

    -- Stripe references
    stripe_customer_id      TEXT,
    stripe_subscription_id  TEXT,

    -- Trial tracking
    trial_started_at        TIMESTAMPTZ,
    trial_ends_at           TIMESTAMPTZ,

    -- Billing period
    current_period_start    TIMESTAMPTZ,
    current_period_end      TIMESTAMPTZ,

    -- Cloud usage limits (USD cents)
    monthly_budget_cents    INT NOT NULL DEFAULT 100,  -- $1.00 trial / $10.00 pro

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(user_id)
);

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own subscription"
    ON public.subscriptions FOR SELECT
    USING (auth.uid() = user_id);

-- Only service_role (Edge Functions) can INSERT/UPDATE/DELETE

-- ============================================================
-- openrouter_keys: per-user OpenRouter API keys
-- ============================================================
CREATE TABLE public.openrouter_keys (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    -- OpenRouter key management
    key_hash    TEXT NOT NULL,           -- OpenRouter key hash (for PATCH/DELETE)
    key_prefix  TEXT,                    -- First 15 chars for display "sk-or-v1-abc..."
    is_active   BOOLEAN NOT NULL DEFAULT true,

    -- Spending limits (synced from OpenRouter)
    limit_usd   NUMERIC(10,4),

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(user_id)
);

ALTER TABLE public.openrouter_keys ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own key metadata"
    ON public.openrouter_keys FOR SELECT
    USING (auth.uid() = user_id);

-- Only service_role can INSERT/UPDATE/DELETE

-- ============================================================
-- usage_logs: audit trail
-- ============================================================
CREATE TABLE public.usage_logs (
    id          BIGSERIAL PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    event_type  TEXT NOT NULL,  -- 'key_created', 'key_rotated', 'plan_changed', etc.
    details     JSONB,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.usage_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own logs"
    ON public.usage_logs FOR SELECT
    USING (auth.uid() = user_id);

-- ============================================================
-- Indexes
-- ============================================================
CREATE INDEX idx_subscriptions_user_id ON public.subscriptions(user_id);
CREATE INDEX idx_subscriptions_stripe_customer ON public.subscriptions(stripe_customer_id);
CREATE INDEX idx_subscriptions_stripe_sub ON public.subscriptions(stripe_subscription_id);
CREATE INDEX idx_openrouter_keys_user_id ON public.openrouter_keys(user_id);
CREATE INDEX idx_usage_logs_user_id ON public.usage_logs(user_id);
CREATE INDEX idx_usage_logs_created_at ON public.usage_logs(created_at);

-- ============================================================
-- Auto-create profile on signup (DB trigger)
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, display_name)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data ->> 'full_name', NEW.email)
    );
    RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- updated_at auto-refresh
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER set_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER set_subscriptions_updated_at
    BEFORE UPDATE ON public.subscriptions
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER set_openrouter_keys_updated_at
    BEFORE UPDATE ON public.openrouter_keys
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
