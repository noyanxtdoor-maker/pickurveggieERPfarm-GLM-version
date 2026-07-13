// Per-user permission overrides (P1C §2.4) — the mockup's "Granular Custom Feature Permissions Override",
// built SERVER-ENFORCED: every read/write goes through user_permission_overrides / set_user_permission_override
// (rank-checked, audited, folded into has_permission). Nothing is stored client-side — no Dexie table, no
// offline queue; this is an online-only admin action, same pattern as Invitations (M1C §9).
import {useEffect, useState} from 'react';
import * as Dialog from '@radix-ui/react-dialog';
import {ShieldAlert, X} from 'lucide-react';
import {supabase} from '../../../core/supabase/client';
import {Button} from '../../../components/ui';
import {useToast} from '../../../components/feedback';
import type {OverrideEffect, Permission} from '../../../types/db';

interface OverrideRow {permission_id: string; effect: OverrideEffect}

const overridesApi = {
  async catalog(): Promise<Permission[]> {
    const {data, error} = await supabase.from('permissions').select('*').eq('status', 'Active').order('permission_key');
    if (error) throw new Error(error.message);
    return (data ?? []) as Permission[];
  },
  async fetch(companyId: string, userId: string): Promise<OverrideRow[]> {
    const {data, error} = await supabase.from('user_permission_overrides').select('permission_id, effect').eq('company_id', companyId).eq('user_id', userId);
    if (error) throw new Error(error.message);
    return (data ?? []) as OverrideRow[];
  },
  async set(companyId: string, userId: string, permissionKey: string, effect: OverrideEffect | null): Promise<void> {
    const {error} = await supabase.rpc('set_user_permission_override', {
      p_company_id: companyId, p_user_id: userId, p_permission_key: permissionKey, p_effect: effect,
    });
    if (error) throw new Error(error.message);
  },
};

export function OverridesDialog({companyId, userId, userName, open, onClose}: {
  companyId: string; userId: string; userName: string; open: boolean; onClose: () => void;
}) {
  const {notify} = useToast();
  const [catalog, setCatalog] = useState<Permission[] | null>(null);
  const [overrides, setOverrides] = useState<Map<string, OverrideEffect>>(new Map());
  const [busyKey, setBusyKey] = useState<string | null>(null);

  const reload = () => {
    Promise.all([overridesApi.catalog(), overridesApi.fetch(companyId, userId)])
      .then(([cat, rows]) => {setCatalog(cat); setOverrides(new Map(rows.map((r) => [r.permission_id, r.effect])));})
      .catch((e) => notify(e instanceof Error ? e.message : 'Failed to load overrides', 'error'));
  };
  useEffect(() => {if (open) reload();}, [open, companyId, userId]); // eslint-disable-line react-hooks/exhaustive-deps

  async function apply(permKey: string, permId: string, effect: OverrideEffect | null) {
    setBusyKey(permId);
    try {
      await overridesApi.set(companyId, userId, permKey, effect);
      notify(effect === null ? `Cleared override on ${permKey}` : `${permKey} ${effect === 'grant' ? 'granted' : 'denied'} for ${userName}`);
      reload();
    } catch (e) { notify(e instanceof Error ? e.message : 'Override failed', 'error'); } finally { setBusyKey(null); }
  }

  return (
    <Dialog.Root open={open} onOpenChange={(o) => {if (!o) onClose();}}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/40" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-50 max-h-[85vh] w-[92vw] max-w-lg -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-2xl bg-farm-card p-6 shadow-xl">
          <div className="mb-1 flex items-center justify-between">
            <Dialog.Title className="flex items-center gap-2 text-xl font-bold text-farm-green"><ShieldAlert className="h-5 w-5" aria-hidden /> Overrides — {userName}</Dialog.Title>
            <Dialog.Close className="rounded p-1 text-farm-muted hover:text-farm-ink" aria-label="Close"><X size={20} aria-hidden /></Dialog.Close>
          </div>
          <p className="mb-4 text-xs text-farm-muted">Grant a key their role lacks, or deny a key their role has. A deny always wins. Server-enforced — this cannot be bypassed client-side.</p>
          {catalog === null ? (
            <p className="py-4 text-sm text-farm-muted">Loading…</p>
          ) : (
            <ul className="divide-y divide-farm-accent-soft">
              {catalog.map((p) => {
                const current = overrides.get(p.id);
                const busy = busyKey === p.id;
                return (
                  <li key={p.id} className="flex items-center justify-between gap-2 py-2.5">
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm font-bold text-farm-ink">{p.permission_key}</p>
                      <p className="truncate text-[11px] text-farm-muted">{p.description}</p>
                    </div>
                    <div className="flex shrink-0 gap-1">
                      <button disabled={busy} onClick={() => void apply(p.permission_key, p.id, 'grant')}
                        className={`rounded-lg border px-2 py-1 text-[10px] font-bold uppercase ${current === 'grant' ? 'border-farm-green bg-farm-green text-white' : 'border-farm-accent-soft text-farm-green hover:bg-farm-accent-soft'}`}>Grant</button>
                      <button disabled={busy} onClick={() => void apply(p.permission_key, p.id, 'deny')}
                        className={`rounded-lg border px-2 py-1 text-[10px] font-bold uppercase ${current === 'deny' ? 'border-farm-danger bg-farm-danger text-white' : 'border-farm-accent-soft text-farm-danger hover:bg-red-50'}`}>Deny</button>
                      <button disabled={busy || !current} onClick={() => void apply(p.permission_key, p.id, null)}
                        className="rounded-lg border border-farm-accent-soft px-2 py-1 text-[10px] font-bold uppercase text-farm-muted hover:bg-farm-accent-soft disabled:opacity-40">Default</button>
                    </div>
                  </li>
                );
              })}
            </ul>
          )}
          <div className="mt-5 flex justify-end border-t border-farm-accent-soft pt-4">
            <Button variant="secondary" onClick={onClose}>Close</Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
