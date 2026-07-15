// Payroll data-access (M1B A1 seam; spec Phase_2_M5_Payroll_Module_Spec.md). Reads: roster (+DERIVED advance
// balance), advances, wage journal. Writes: employee master via RLS (mock→Dexie / online→PostgREST / offline→
// outbox); advances + wages via governed rpc (mock→Dexie / online→rpc / offline→outbox-queued). GL truth is the
// server; mock reconstructs the same figures locally.
import {supabase} from '../../core/supabase/client';
import {offlineDB} from '../../core/offline/db';
import {enqueue} from '../../core/offline/queue';
import {uuidv7} from '../../core/offline/uuidv7';
import {MOCK_MODE} from '../../core/mock/mock';
import {round2} from '../pos/money';
import type {CashAdvance, Employee, WagePayment} from '../../types/db';

const online = () => typeof navigator === 'undefined' || navigator.onLine;
const todayISO = () => new Date().toISOString().slice(0, 10);

// Derived outstanding advance (Σ advances − Σ wage deductions) — mirrors employee_advance_balance() / the mock.
async function mockAdvanceBalance(companyId: string, employeeId: string): Promise<number> {
  const advs = await offlineDB.cashAdvances.where('company_id').equals(companyId).filter((a) => a.employee_id === employeeId).toArray();
  const wages = await offlineDB.wagePayments.where('company_id').equals(companyId).filter((w) => w.employee_id === employeeId).toArray();
  return round2(advs.reduce((s, a) => s + a.amount, 0) - wages.reduce((s, w) => s + w.ca_deducted, 0));
}

export interface Position {
  id: string;
  company_id: string;
  label: string;
  active: boolean;
  created_by: string; // server-derived (positions_normalize_and_check trigger sets it from the actor)
  created_at: string;
  updated_at: string;
}

export interface HireInput {
  name: string;
  positionId: string | null; // P1D: FK to public.positions (null = no position assigned)
  dailyRate: number;
}

export const payrollApi = {
  // P1D: fetch the company's active position picklist (positions table; deactive never deleted).
  async fetchPositions(companyId: string): Promise<Position[]> {
    if (MOCK_MODE) return []; // mock has no seeded positions; the form degrades to "no assignment"
    // Return ALL positions (active + inactive) so the Position Management dialog can show + toggle
    // inactive ones. The hire-form picklist filters to active client-side (activePositions).
    const {data, error} = await supabase.from('positions').select('id, company_id, label, active, created_by, created_at, updated_at').eq('company_id', companyId).order('label');
    if (error) throw new Error(error.message);
    return (data ?? []) as Position[];
  },

  // P1D: add a new position to the picklist. created_by is server-derived (never client-supplied —
  // see positions_normalize_and_check trigger); the createdBy client arg is unused on the wire (mock
  // is a no-op — Repo B's Dexie schema has no positions store; positions are a real-DB surface only).
  async addPosition(companyId: string, label: string, _createdBy: string): Promise<void> {
    if (!label.trim()) throw new Error('Position name is required.');
    if (MOCK_MODE) return; // mock has no positions store; fetchPositions returns [] in mock
    const {error} = await supabase.from('positions').insert({company_id: companyId, label: label.trim()});
    if (error) throw new Error(error.message);
  },

  // P1D: deactivate (never delete — the picklist preserves history). Active toggle.
  async setPositionActive(position: Position, active: boolean): Promise<void> {
    if (MOCK_MODE) return;
    const {error} = await supabase.from('positions').update({active}).eq('id', position.id);
    if (error) throw new Error(error.message);
  },

  async fetchEmployees(companyId: string): Promise<Employee[]> {
    if (MOCK_MODE) {
      const rows = await offlineDB.employees.where('company_id').equals(companyId).toArray();
      const out: Employee[] = [];
      for (const r of rows) out.push({...r, advance_balance: await mockAdvanceBalance(companyId, r.id)});
      return out.sort((a, b) => Number(b.status === 'Active') - Number(a.status === 'Active') || a.name.localeCompare(b.name));
    }
    // P1D: join positions to get the label for display (one-level PostgREST nest).
    const {data, error} = await supabase.from('employees').select('*, positions(label)').eq('company_id', companyId).order('name');
    if (error) throw new Error(error.message);
    const rows = (data ?? []) as Array<Employee & {positions: {label: string} | {label: string}[] | null}>;
    const out: Employee[] = [];
    for (const r of rows) {
      const label = Array.isArray(r.positions) ? (r.positions[0]?.label ?? null) : (r.positions?.label ?? null);
      const {position_label: _drop, advance_balance: _drop2, ...rest} = r;
      void _drop; void _drop2; // strip client-side-only fields before passing to the balance RPC
      const {data: bal, error: e2} = await supabase.rpc('employee_advance_balance', {p_employee_id: rest.id});
      if (e2) throw new Error(e2.message);
      out.push({...rest, position_label: label, daily_rate: Number(rest.daily_rate), advance_balance: Number(bal ?? 0)});
    }
    return out.sort((a, b) => Number(b.status === 'Active') - Number(a.status === 'Active') || a.name.localeCompare(b.name));
  },

  async hire(companyId: string, input: HireInput): Promise<void> {
    if (!input.name.trim()) throw new Error('Worker name is required.');
    if (!(input.dailyRate > 0)) throw new Error('Daily rate must be greater than ₱0.');
    const code = `EMP-${uuidv7().slice(-6).toUpperCase()}`;
    // P1D: send position_id (uuid FK to public.positions), not the old `position` text column.
    const payload = {company_id: companyId, employee_code: code, name: input.name.trim(), position_id: input.positionId, daily_rate: round2(input.dailyRate), date_hired: todayISO()};
    if (MOCK_MODE) {
      const now = new Date().toISOString();
      await offlineDB.employees.put({id: uuidv7(), ...payload, status: 'Active', user_id: null, created_at: now, updated_at: now});
      return;
    }
    if (online()) {
      const {error} = await supabase.from('employees').insert(payload);
      if (error) throw new Error(error.message);
      return;
    }
    await enqueue({companyId, kind: 'payroll.hire', request: {type: 'insert', table: 'employees', payload}});
  },

  async setActive(employee: Employee, active: boolean): Promise<void> {
    const status = active ? 'Active' : 'Inactive';
    if (MOCK_MODE) {
      const {advance_balance: _drop1, position_label: _drop2, ...row} = employee;
      await offlineDB.employees.put({...row, status, updated_at: new Date().toISOString()});
      return;
    }
    if (online()) {
      const {error} = await supabase.from('employees').update({status}).eq('id', employee.id);
      if (error) throw new Error(error.message);
      return;
    }
    await enqueue({companyId: employee.company_id, kind: 'payroll.employee.update', request: {type: 'update', table: 'employees', match: {id: employee.id, baseUpdatedAt: employee.updated_at}, payload: {status}}});
  },

  // P2-M5C self view: one employee's advances/wages across ALL branches (your pay follows you).
  // Real mode relies on the self-visibility RLS to authorize the rows; mock filters locally.
  async fetchEmployeeAdvances(companyId: string, employeeId: string): Promise<CashAdvance[]> {
    if (MOCK_MODE) {
      const rows = await offlineDB.cashAdvances.where('company_id').equals(companyId).filter((a) => a.employee_id === employeeId).toArray();
      return rows.sort((a, b) => b.created_at.localeCompare(a.created_at));
    }
    const {data, error} = await supabase.from('cash_advances').select('*').eq('company_id', companyId).eq('employee_id', employeeId).order('created_at', {ascending: false}).limit(300);
    if (error) throw new Error(error.message);
    return ((data ?? []) as CashAdvance[]).map((a) => ({...a, amount: Number(a.amount)}));
  },

  async fetchEmployeeWages(companyId: string, employeeId: string): Promise<WagePayment[]> {
    if (MOCK_MODE) {
      const rows = await offlineDB.wagePayments.where('company_id').equals(companyId).filter((w) => w.employee_id === employeeId).toArray();
      return rows.sort((a, b) => b.created_at.localeCompare(a.created_at));
    }
    const {data, error} = await supabase.from('wage_payments').select('*').eq('company_id', companyId).eq('employee_id', employeeId).order('created_at', {ascending: false}).limit(300);
    if (error) throw new Error(error.message);
    return ((data ?? []) as WagePayment[]).map((w) => ({...w, days_worked: Number(w.days_worked), daily_rate: Number(w.daily_rate), gross: Number(w.gross), ca_deducted: Number(w.ca_deducted), net: Number(w.net)}));
  },

  // P2-M5C: link/unlink a staff record to an app user (payroll self-visibility). Governed rpc; audited server-side.
  async linkEmployeeUser(employee: Employee, userId: string | null): Promise<void> {
    if (MOCK_MODE) {
      const {advance_balance: _drop1, position_label: _drop2, ...row} = employee;
      await offlineDB.employees.put({...row, user_id: userId, updated_at: new Date().toISOString()});
      return;
    }
    const payload = {p_employee_id: employee.id, p_user_id: userId};
    if (online()) {
      const {error} = await supabase.rpc('payroll_link_employee_user', payload);
      if (error) throw new Error(error.message);
      return;
    }
    await enqueue({companyId: employee.company_id, kind: 'payroll.link_user', request: {type: 'rpc', rpc: 'payroll_link_employee_user', payload}});
  },

  async fetchAdvances(companyId: string, branchId: string): Promise<CashAdvance[]> {
    if (MOCK_MODE) {
      const rows = await offlineDB.cashAdvances.where('company_id').equals(companyId).filter((a) => a.branch_id === branchId).toArray();
      return rows.sort((a, b) => b.created_at.localeCompare(a.created_at));
    }
    const {data, error} = await supabase.from('cash_advances').select('*').eq('company_id', companyId).eq('branch_id', branchId).order('created_at', {ascending: false}).limit(300);
    if (error) throw new Error(error.message);
    return ((data ?? []) as CashAdvance[]).map((a) => ({...a, amount: Number(a.amount)}));
  },

  async recordAdvance(companyId: string, branchId: string, employee: Employee, amount: number, note: string): Promise<void> {
    if (!(amount > 0)) throw new Error('Advance amount must be greater than ₱0.');
    if (employee.status !== 'Active') throw new Error('Employee is not active.');
    const idem = uuidv7();
    if (MOCK_MODE) {
      await offlineDB.cashAdvances.put({id: idem, company_id: companyId, branch_id: branchId, employee_id: employee.id, amount: round2(amount), note: note.trim() || null, created_at: new Date().toISOString()});
      return;
    }
    const payload = {p_branch_id: branchId, p_employee_id: employee.id, p_amount: round2(amount), p_note: note.trim() || null, p_idempotency_key: idem};
    if (online()) {
      const {error} = await supabase.rpc('payroll_record_cash_advance', payload);
      if (error) throw new Error(error.message);
      return;
    }
    await enqueue({companyId, kind: 'payroll.advance', request: {type: 'rpc', rpc: 'payroll_record_cash_advance', payload}});
  },

  async fetchWages(companyId: string, branchId: string): Promise<WagePayment[]> {
    if (MOCK_MODE) {
      const rows = await offlineDB.wagePayments.where('company_id').equals(companyId).filter((w) => w.branch_id === branchId).toArray();
      return rows.sort((a, b) => b.created_at.localeCompare(a.created_at));
    }
    const {data, error} = await supabase.from('wage_payments').select('*').eq('company_id', companyId).eq('branch_id', branchId).order('created_at', {ascending: false}).limit(300);
    if (error) throw new Error(error.message);
    return ((data ?? []) as WagePayment[]).map((w) => ({...w, days_worked: Number(w.days_worked), daily_rate: Number(w.daily_rate), gross: Number(w.gross), ca_deducted: Number(w.ca_deducted), net: Number(w.net)}));
  },

  // Disburse a wage: gross = days × rate (server recomputes; mock mirrors). Returns nothing (caller reloads).
  async disburseWage(companyId: string, branchId: string, employee: Employee, payPeriod: string, daysWorked: number, caDeduction: number, notes: string): Promise<void> {
    if (!(daysWorked > 0)) throw new Error('Days worked must be greater than 0.');
    if (caDeduction < 0) throw new Error('Deduction cannot be negative.');
    const gross = round2(daysWorked * employee.daily_rate);
    if (caDeduction > gross) throw new Error('Deduction exceeds the gross wage.');
    const idem = uuidv7();
    if (MOCK_MODE) {
      const outstanding = await mockAdvanceBalance(companyId, employee.id);
      if (caDeduction > outstanding) throw new Error(`Deduction exceeds the outstanding advance (₱${outstanding}).`);
      await offlineDB.wagePayments.put({
        id: idem, company_id: companyId, branch_id: branchId, employee_id: employee.id,
        pay_period: payPeriod.trim() || 'Cycle', days_worked: daysWorked, daily_rate: employee.daily_rate,
        gross, ca_deducted: round2(caDeduction), net: round2(gross - caDeduction), notes: notes.trim() || null,
        created_at: new Date().toISOString(),
      });
      return;
    }
    const payload = {p_branch_id: branchId, p_employee_id: employee.id, p_pay_period: payPeriod.trim() || 'Cycle', p_days_worked: daysWorked, p_ca_deduction: round2(caDeduction), p_notes: notes.trim() || null, p_idempotency_key: idem};
    if (online()) {
      const {error} = await supabase.rpc('payroll_disburse_wage', payload);
      if (error) throw new Error(error.message);
      return;
    }
    await enqueue({companyId, kind: 'payroll.wage', request: {type: 'rpc', rpc: 'payroll_disburse_wage', payload}});
  },
};
