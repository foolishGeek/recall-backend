// Deploy shell — full RevenueCat webhook contract lands in S23. Deployed with
// verify_jwt = false (config.toml) so RevenueCat can POST without a Supabase JWT.
import { stubFunction } from "../_shared/stub.ts";
stubFunction("revenuecat-webhook", "S23");
