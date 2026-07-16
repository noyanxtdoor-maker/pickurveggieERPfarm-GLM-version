// P1C2 (2026-07-16): the merged 3-state permission panel (Item C). Reads the module access state
// for a (user, module) via public.user_module_access(p_company_id, p_user_id, p_module); writes go
// through the proven set_user_permission_override RPC — one call per module representative key.
// The toggle DROPS the user to None by clearing both module representative keys via the same RPC.
// Authority chain: AGENTS.md §2 (non-money-path) → M1C §8.5 (permission model).
import {supabase} from '../../../core/supabase/client';
import {MOCK_MODE} from '../../../core/mock/mock';

export type ModuleAccessTier = 'none' | 'view' | 'manage';
export interface ModuleOption {
  module: string;
  readKey: string | null;
  manageKey: string | null;
  keys: string[]; // all keys under the module; presented for transparency in the panel
}

export const moduleAccessApi = {
  /** List every non-system module with its representative read/manage keys + every other key in the module. */
  async catalog(): Promise<ModuleOption[]> {
    if (MOCK_MODE) {
      return [
        {module: 'organization', readKey: 'user.read', manageKey: 'membership.manage', keys: ['user.read', 'audit.read', 'membership.read', 'role.manage', 'branch.manage', 'user.invite', 'membership.manage', 'company.manage', 'position.manage', 'job_title.manage']},
        {module: 'inventory', readKey: null, manageKey: 'inventory.purchase', keys: ['inventory.adjust', 'inventory.opening', 'inventory.purchase', 'equipment.manage']},
        {module: 'pos', readKey: null, manageKey: 'pos.sell', keys: ['pos.sell', 'pos.void', 'pos.settle', 'cash.session', 'product.manage']},
        {module: 'accounting', readKey: 'accounting.read', manageKey: 'accounting.manage', keys: ['accounting.read', 'accounting.manage']},
        {module: 'payroll', readKey: 'payroll.read', manageKey: 'payroll.manage', keys: ['payroll.read', 'payroll.manage']},
        {module: 'scheduling', readKey: 'schedule.read', manageKey: 'schedule.manage', keys: ['schedule.read', 'schedule.manage', 'schedule.read_private']},
        {module: 'projects', readKey: 'project.read', manageKey: 'project.manage', keys: ['project.read', 'project.manage']},
        {module: 'customers', readKey: 'customer.read', manageKey: 'customer.manage', keys: ['customer.read', 'customer.manage']},
      ];
    }
    const [mods, allKeys] = await Promise.all([
      supabase.from('permission_modules').select('module, read_key, manage_key').order('module'),
      supabase.from('permissions').select('module, permission_key').eq('status', 'Active').not('module', 'is', null),
    ]);
    if (mods.error) throw new Error(mods.error.message);
    if (allKeys.error) throw new Error(allKeys.error.message);
    const byModule: Record<string, ModuleOption> = {};
    for (const r of mods.data ?? []) {
      byModule[r.module] = {module: r.module, readKey: r.read_key ?? null, manageKey: r.manage_key ?? null, keys: []};
    }
    for (const k of allKeys.data ?? []) {
      if (!k.module) continue;
      const m = byModule[k.module] ?? (byModule[k.module] = {module: k.module, readKey: null, manageKey: null, keys: []});
      m.keys.push(k.permission_key);
    }
    return Object.values(byModule).filter((m) => m.module !== 'system').sort((a, b) => a.module.localeCompare(b.module));
  },

  /** Read the current tier for a (user, module) using the resolver (or the v_user_id-independent fallback for catalog). */
  async tier(p_company_id: string, p_user_id: string, p_module: string): Promise<ModuleAccessTier> {
    if (MOCK_MODE) return 'none';
    const {data, error} = await supabase.rpc('user_module_access', {p_company_id, p_user_id, p_module});
    if (error) throw new Error(error.message);
    return (data ?? 'none') as ModuleAccessTier;
  },

  /**
   * Apply a target tier to a (user, module) pair. Derived calls to the proven
   * set_user_permission_override (one per representative key).
   *
   *   target = manage: re-grant the manage key + grant any read key (so the user sees .read records).
   *   target = view:  grant the read key + deny the manage key (deny enforces "no .manage actions").
   *   target = none:  clear both representative keys (effect = null => deletion in the RPC).
   *
   * If the module has only a manage key (e.g. pos/inventory have no .read), the corresponding
   * grant/deny/clear call is skipped silently.
   */
  async apply(p_company_id: string, p_user_id: string, mod: ModuleOption, target: ModuleAccessTier): Promise<void> {
    if (MOCK_MODE) return;
    const {readKey, manageKey} = mod;
    const errors: string[] = [];
    if (readKey) {
      const readEffect = target === 'none' ? null : 'grant';
      const {error} = await supabase.rpc('set_user_permission_override', {p_company_id, p_user_id, p_permission_key: readKey, p_effect: readEffect});
      if (error) errors.push(error.message);
    }
    if (manageKey) {
      const manageEffect: 'grant' | 'deny' | null = target === 'manage' ? 'grant' : target === 'view' ? 'deny' : null;
      const {error} = await supabase.rpc('set_user_permission_override', {p_company_id, p_user_id, p_permission_key: manageKey, p_effect: manageEffect});
      if (error) errors.push(error.message);
    }
    if (errors.length > 0) throw new Error(errors.join('; '));
  },
};
