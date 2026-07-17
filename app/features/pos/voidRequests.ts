// PERM item 6 (2026-07-16): client API for void-sale approval requests.
// Reads/writes go through the proven SECURITY DEFINER RPCs (request_void,
// list_void_requests, approve_void_request, reject_void_request). All gating happens
// on the server; this module is a thin RPC client + UI-friendly types.
// Authority chain: AGENTS.md §2 (money-path gate: voids hit GL reversals — guarded
// by the P2N2 migration + 6-assertion guard battery, all green on 2026-07-16).
import {supabase} from '../../core/supabase/client';
import {MOCK_MODE} from '../../core/mock/mock';

export interface VoidRequest {
  id: string;
  invoice_id: string;
  invoice_number: number | null;
  branch_id: string;
  branch_name: string | null;
  requested_by: string;
  requester_name: string | null;
  reason: string;
  created_at: string;
}

export const voidRequestsApi = {
  async list(): Promise<VoidRequest[]> {
    if (MOCK_MODE) return [];
    const {data, error} = await supabase.rpc('list_void_requests');
    if (error) throw new Error(error.message);
    return (data ?? []) as VoidRequest[];
  },

  /** File a void request for an invoice. Resolves to the new request id. */
  async request(p_invoice_id: string, p_reason: string): Promise<string> {
    if (MOCK_MODE) return 'mock-void-request-id';
    const {data, error} = await supabase.rpc('request_void', {p_invoice_id, p_reason});
    if (error) throw new Error(error.message);
    return data as string;
  },

  async approve(p_request_id: string): Promise<void> {
    if (MOCK_MODE) return;
    const {error} = await supabase.rpc('approve_void_request', {p_request_id});
    if (error) throw new Error(error.message);
  },

  async reject(p_request_id: string, p_reason: string): Promise<void> {
    if (MOCK_MODE) return;
    const {error} = await supabase.rpc('reject_void_request', {p_request_id, p_reason});
    if (error) throw new Error(error.message);
  },
};
