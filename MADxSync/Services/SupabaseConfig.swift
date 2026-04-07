//
//  SupabaseConfig.swift
//  MADxSync
//
//  Single source of truth for Supabase project credentials.
//
//  CREATED: 2026-04 — Centralizes the publishable key and project URL that were
//  previously duplicated across 14 service files. If the key ever needs rotation,
//  change it here and nowhere else.
//
//  NOTE: This is the PUBLISHABLE (anon) key, not the service_role key.
//  It is safe to ship in the app binary — Supabase RLS policies enforce
//  all access control server-side via the auth token + district_id.
//

import Foundation

enum SupabaseConfig {
    static let url = "https://amclxjjsialotyuombxg.supabase.co"
    static let publishableKey = "sb_publishable_hefimLQMjSHhL3OQGmzn5g_0wcJMf7L"
}
