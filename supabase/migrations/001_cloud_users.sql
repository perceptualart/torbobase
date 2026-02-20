-- Torbo Base Cloud — Supabase Schema Migration
-- (c) 2026 Perceptual Art LLC — Apache 2.0
--
-- Run this in Supabase SQL Editor or via supabase db push.
-- This creates the cloud_users table for tracking user subscriptions and usage.

-- Cloud Users table — tracks subscription and usage data per user
CREATE TABLE IF NOT EXISTS cloud_users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    plan_tier TEXT NOT NULL DEFAULT 'torbo' CHECK (plan_tier IN ('free_base', 'torbo', 'torbo_max')),
    stripe_customer_id TEXT,
    stripe_subscription_id TEXT,
    subscription_status TEXT DEFAULT 'none',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_active TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    daily_message_count INTEGER NOT NULL DEFAULT 0,
    last_message_date DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Index for Stripe customer lookups (webhook handling)
CREATE INDEX IF NOT EXISTS idx_cloud_users_stripe_customer ON cloud_users(stripe_customer_id)
    WHERE stripe_customer_id IS NOT NULL;

-- Index for subscription status queries
CREATE INDEX IF NOT EXISTS idx_cloud_users_plan_tier ON cloud_users(plan_tier);

-- Row Level Security — users can only read their own record
ALTER TABLE cloud_users ENABLE ROW LEVEL SECURITY;

-- Users can read their own record
CREATE POLICY "Users can read own record"
    ON cloud_users
    FOR SELECT
    USING (auth.uid() = id);

-- Service role can do everything (for server-side operations)
CREATE POLICY "Service role full access"
    ON cloud_users
    FOR ALL
    USING (auth.role() = 'service_role')
    WITH CHECK (auth.role() = 'service_role');

-- Automatically create a cloud_users record when a new user signs up
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO cloud_users (id, email, plan_tier, created_at, last_active)
    VALUES (NEW.id, NEW.email, 'torbo', NOW(), NOW())  -- New signups start on Torbo (with free trial)
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger on auth.users insert
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION handle_new_user();

-- Usage tracking table (optional — for detailed analytics)
CREATE TABLE IF NOT EXISTS usage_log (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES cloud_users(id) ON DELETE CASCADE,
    event_type TEXT NOT NULL,    -- 'message', 'tts', 'tool_call', etc.
    agent_id TEXT,
    model TEXT,
    tokens_used INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index for user usage queries
CREATE INDEX IF NOT EXISTS idx_usage_log_user_date ON usage_log(user_id, created_at DESC);

-- Partition by month for large-scale deployments (optional)
-- CREATE TABLE usage_log_2026_02 PARTITION OF usage_log FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');

-- Grant access to service role
GRANT ALL ON cloud_users TO service_role;
GRANT ALL ON usage_log TO service_role;
GRANT USAGE, SELECT ON SEQUENCE usage_log_id_seq TO service_role;
