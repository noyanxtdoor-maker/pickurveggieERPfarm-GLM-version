// PERM item 2 (2026-07-16): client API for crop pricing approval requests.
// Reads/writes go through the proven SECURITY DEFINER RPCs (request_price_change,
// list_price_change_requests, approve_price_change, reject_price_change). All gating happens on
// the server; this module is a thin RPC client + UI-friendly types.
// Authority chain: AGENTS.md §2 (non-money-path, but money-adjacent price floor — banned
// per-row guards + RPC-only writes).
import {supabase} from '../../core/supabase/client';
import {MOCK_MODE} from '../../core/mock/mock';

export interface PriceChangeRequest {
  id: string;
  company_id: string;
  product_id: string;
  product_name: string;
  product_code: string;
  current_retail_per_kg: number;
  requested_retail_per_kg: number;
  requester_user_id: string;
  requester_name: string | null;
  status: 'Pending' | 'Approved' | 'Rejected';
  created_at: string;
  approver_user_id: string | null;
  resolved_at: string | null;
  rejection_reason: string | null;
}

export const priceChangeRequestsApi = {
  async list(): Promise<PriceChangeRequest[]> {
    if (MOCK_MODE) return [];
    const {data, error} = await supabase.rpc('list_price_change_requests');
    if (error) throw new Error(error.message);
    return (data ?? []) as PriceChangeRequest[];
  },

  /** File a request for a single product. Resolves to the new request id. */
  async request(p_product_id: string, p_new_price: number): Promise<string> {
    if (MOCK_MODE) return 'mock-request-id';
    const {data, error} = await supabase.rpc('request_price_change', {p_product_id, p_new_price: p_new_price});
    if (error) throw new Error(error.message);
    return data as string;
  },

  async approve(p_request_id: string): Promise<void> {
    if (MOCK_MODE) return;
    const {error} = await supabase.rpc('approve_price_change', {p_request_id});
    if (error) throw new Error(error.message);
  },

  async reject(p_request_id: string, p_reason: string): Promise<void> {
    if (MOCK_MODE) return;
    const {error} = await supabase.rpc('reject_price_change', {p_request_id, p_rejection_reason: p_reason});
    if (error) throw new Error(error.message);
  },
};
