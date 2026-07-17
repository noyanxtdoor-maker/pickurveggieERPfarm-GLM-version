// T3.1 (2026-07-16): client API for vendor master + cost schedule + vendor ledger (AP).
// All writes go through the proven SECURITY DEFINER RPCs (vendor_upsert,
// cost_schedule_upsert, vendor_invoice_record, vendor_payment_record, vendor_ap_standing).
// Reads come from vendor_ap_standing (the derived balance view function) + a vendors select.
// Authority chain: AGENTS.md §2 (money-path gate: vendor invoice + payment write GL — guarded
// by the T3.1 migration + 8-assertion guard battery, all green on 2026-07-16).
import {supabase} from '../../core/supabase/client';
import {MOCK_MODE} from '../../core/mock/mock';

export interface Vendor {
  id: string;
  company_id: string;
  vendor_code: string;
  name: string;
  contact: string | null;
  address: string | null;
  tax_id: string | null;
  payment_terms: string | null;
  notes: string | null;
  status: 'Active' | 'Archived';
  created_at: string;
}

export interface VendorAPStanding {
  vendor_id: string;
  name: string;
  status: 'Active' | 'Archived';
  total_invoiced: number;
  total_paid: number;
  outstanding_ap: number;
}

export interface CostScheduleRow {
  id: string;
  company_id: string;
  vendor_id: string;
  product_id: string;
  unit_cost: number;
  effective_from: string;
  effective_to: string | null;
  notes: string | null;
  created_at: string;
}

export interface VendorInvoiceLineInput {
  product_id?: string | null;
  description?: string;
  quantity: number;
  unit_cost: number;
  expense_account_id: string;
  cost_schedule_id?: string | null;
}

export interface VendorPaymentAllocation {
  vendor_invoice_id: string;
  amount: number;
}

export const vendorsApi = {
  async list(): Promise<Vendor[]> {
    if (MOCK_MODE) return [];
    const {data, error} = await supabase.from('vendors').select('*').order('name');
    if (error) throw new Error(error.message);
    return (data ?? []) as Vendor[];
  },

  async standing(p_vendor_id: string | null = null): Promise<VendorAPStanding[]> {
    if (MOCK_MODE) return [];
    const {data, error} = await supabase.rpc('vendor_ap_standing', {p_company: (await this._companyId())!, p_vendor_id: p_vendor_id});
    if (error) throw new Error(error.message);
    return (data ?? []) as VendorAPStanding[];
  },

  async upsert(p_id: string | null, p_code: string, p_name: string, p_contact: string | null = null,
               p_address: string | null = null, p_tax_id: string | null = null,
               p_payment_terms: string | null = null, p_notes: string | null = null): Promise<string> {
    if (MOCK_MODE) return 'mock-vendor-id';
    const companyId = await this._companyId();
    if (!companyId) throw new Error('No company context');
    const {data, error} = await supabase.rpc('vendor_upsert', {
      p_company: companyId, p_id, p_vendor_code: p_code, p_name,
      p_contact, p_address, p_tax_id, p_payment_terms, p_notes,
    });
    if (error) throw new Error(error.message);
    return data as string;
  },

  async upsertCostSchedule(p_id: string | null, p_vendor_id: string, p_product_id: string,
                           p_unit_cost: number, p_effective_from: string,
                           p_effective_to: string | null = null, p_notes: string | null = null): Promise<string> {
    if (MOCK_MODE) return 'mock-cs-id';
    const companyId = await this._companyId();
    if (!companyId) throw new Error('No company context');
    const {data, error} = await supabase.rpc('cost_schedule_upsert', {
      p_company: companyId, p_id, p_vendor_id, p_product_id,
      p_unit_cost, p_effective_from, p_effective_to, p_notes,
    });
    if (error) throw new Error(error.message);
    return data as string;
  },

  async recordInvoice(p_branch_id: string, p_vendor_id: string, p_invoice_number: string,
                      p_invoice_date: string, p_due_date: string | null,
                      p_lines: VendorInvoiceLineInput[], p_notes: string | null = null): Promise<string> {
    if (MOCK_MODE) return 'mock-invoice-id';
    const companyId = await this._companyId();
    if (!companyId) throw new Error('No company context');
    const {data, error} = await supabase.rpc('vendor_invoice_record', {
      p_company: companyId, p_branch_id: p_branch_id, p_vendor_id: p_vendor_id,
      p_invoice_number: p_invoice_number, p_invoice_date: p_invoice_date, p_due_date: p_due_date,
      p_lines: p_lines as never, p_notes: p_notes,
    });
    if (error) throw new Error(error.message);
    return data as string;
  },

  async recordPayment(p_branch_id: string, p_vendor_id: string, p_payment_date: string,
                      p_amount: number, p_allocations: VendorPaymentAllocation[],
                      p_method: string = 'Cash', p_reference: string | null = null,
                      p_notes: string | null = null): Promise<string> {
    if (MOCK_MODE) return 'mock-payment-id';
    const companyId = await this._companyId();
    if (!companyId) throw new Error('No company context');
    const {data, error} = await supabase.rpc('vendor_payment_record', {
      p_company: companyId, p_branch_id: p_branch_id, p_vendor_id: p_vendor_id,
      p_payment_date: p_payment_date, p_amount: p_amount, p_allocations: p_allocations as never,
      p_method: p_method, p_reference: p_reference, p_notes: p_notes,
    });
    if (error) throw new Error(error.message);
    return data as string;
  },

  async _companyId(): Promise<string | null> {
    const {data} = await supabase.auth.getUser();
    // company id is derived from the user's active membership; the rpc takes it explicitly.
    // We piggyback on a small lookup: read user_branch_roles for the current user.
    const {data: rows} = await supabase.from('user_branch_roles').select('company_id').eq('assignment_status', 'Active').limit(1);
    return rows?.[0]?.company_id ?? null;
  },
};
