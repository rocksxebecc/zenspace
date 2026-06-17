-- ============================================================
--  Zenspace — Promo Codes & Admin Access System
--  Run ALL of this in your Supabase SQL Editor
-- ============================================================

-- 1. Add is_admin column to profiles
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT false;

-- 2. Create promo_codes table
CREATE TABLE IF NOT EXISTS public.promo_codes (
  code          TEXT PRIMARY KEY,
  created_by    UUID REFERENCES auth.users(id),
  max_uses      INT NOT NULL DEFAULT 1,        -- 0 = unlimited uses
  current_uses  INT NOT NULL DEFAULT 0,
  duration_days INT NOT NULL DEFAULT 36500,    -- 36500 days ≈ 100 years = lifetime
  is_active     BOOLEAN NOT NULL DEFAULT true,
  notes         TEXT,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE public.promo_codes ENABLE ROW LEVEL SECURITY;

-- Admins can fully manage codes
CREATE POLICY "Admin manage promo_codes" ON public.promo_codes
  FOR ALL USING (
    EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND is_admin = true)
  );

-- Anyone can read active codes (needed for the RPC function)
CREATE POLICY "Anyone read active codes" ON public.promo_codes
  FOR SELECT USING (is_active = true);

-- 3. Code redemptions table (tracks who used which code)
CREATE TABLE IF NOT EXISTS public.code_redemptions (
  id          UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  code        TEXT REFERENCES public.promo_codes(code) ON DELETE CASCADE,
  user_id     UUID REFERENCES auth.users(id),
  redeemed_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(code, user_id)
);

ALTER TABLE public.code_redemptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users view own redemptions" ON public.code_redemptions
  FOR SELECT USING (auth.uid() = user_id);

-- 4. Atomic redeem function (SECURITY DEFINER = bypasses RLS, runs as postgres)
CREATE OR REPLACE FUNCTION public.redeem_promo_code(p_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_code    RECORD;
  v_user_id UUID := auth.uid();
  v_expires TIMESTAMPTZ;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Not authenticated');
  END IF;

  -- Look up code (case-insensitive, trim whitespace)
  SELECT * INTO v_code
  FROM public.promo_codes
  WHERE UPPER(TRIM(code)) = UPPER(TRIM(p_code)) AND is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Invalid or inactive code');
  END IF;

  -- Check max uses (0 = unlimited)
  IF v_code.max_uses > 0 AND v_code.current_uses >= v_code.max_uses THEN
    RETURN jsonb_build_object('success', false, 'error', 'This code has reached its usage limit');
  END IF;

  -- Check not already redeemed by this user
  IF EXISTS (
    SELECT 1 FROM public.code_redemptions
    WHERE UPPER(TRIM(code)) = UPPER(TRIM(p_code)) AND user_id = v_user_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'You have already redeemed this code');
  END IF;

  -- Calculate expiry (NULL = never expires)
  v_expires := CASE
    WHEN v_code.duration_days >= 36400 THEN NULL
    ELSE NOW() + (v_code.duration_days || ' days')::INTERVAL
  END;

  -- Record redemption
  INSERT INTO public.code_redemptions (code, user_id)
  VALUES (v_code.code, v_user_id);

  -- Increment usage count
  UPDATE public.promo_codes
  SET current_uses = current_uses + 1
  WHERE code = v_code.code;

  -- Activate / extend subscription
  INSERT INTO public.subscriptions (user_id, plan, status, amount, starts_at, expires_at)
  VALUES (v_user_id, 'pro', 'active', 0, NOW(), v_expires)
  ON CONFLICT (user_id) DO UPDATE SET
    plan       = 'pro',
    status     = 'active',
    starts_at  = NOW(),
    expires_at = EXCLUDED.expires_at,
    updated_at = NOW();

  RETURN jsonb_build_object('success', true, 'message', 'Access granted! Welcome to Pro.');
END;
$$;

-- ============================================================
--  STEP A: Make yourself an admin
--  Replace YOUR_EMAIL with your actual login email
-- ============================================================
-- UPDATE public.profiles SET is_admin = true
-- WHERE id = (SELECT id FROM auth.users WHERE email = 'YOUR_EMAIL@example.com');

-- ============================================================
--  STEP B: Create your first owner code (optional)
--  You can also create codes from the Admin Panel in the dashboard
-- ============================================================
-- INSERT INTO public.promo_codes (code, max_uses, duration_days, notes)
-- VALUES ('ZENOWNER', 0, 36500, 'Owner lifetime access — unlimited uses')
-- ON CONFLICT DO NOTHING;
