// P1C2 (2026-07-16): the merged "Set Permissions" panel for Item C — 3-state module toggle
// (Not Visible / View-only / Edit & Manage) per module, per user. Opens from a row-level Access
// button on the Active POS User Directory. Reads the current tier via user_module_access RPC;
// writes via the proven set_user_permission_override RPC (one call per representative key).
// The panel renders 8 module rows (organization, inventory, pos, accounting, payroll, scheduling,
// projects, customers) in a single dialog — that is the Item C "merge" of the old Set Permissions
// per-key view + the binary Grant/Deny overrides dialog into ONE 3-state module view.
import {useEffect, useMemo, useState} from 'react';
import * as Dialog from '@radix-ui/react-dialog';
import {Eye, Lock, ShieldCheck, X, ChevronDown} from 'lucide-react';
import {Button} from '../../../components/ui';
import {EmptyState, useToast} from '../../../components/feedback';
import {moduleAccessApi, type ModuleAccessTier, type ModuleOption} from './moduleAccess';

interface AccessSelections { [module: string]: ModuleAccessTier }

interface Props {
  companyId: string;
  userId: string;
  userName: string;
  open: boolean;
  onClose: () => void;
}

const TIERS: Array<{tier: ModuleAccessTier; label: string; hint: string; icon: typeof Eye}> = [
  {tier: 'none', label: 'Not Visible',  hint: 'Hides the module from this user', icon: Lock},
  {tier: 'view', label: 'View-only',    hint: 'Can see records; cannot edit',   icon: Eye},
  {tier: 'manage', label: 'Edit & Manage', hint: 'Full access to this module', icon: ShieldCheck},
];

function colorFor(tier: ModuleAccessTier, current: ModuleAccessTier): string {
  if (current !== tier) return 'border-farm-accent-soft text-farm-muted hover:bg-farm-accent-soft';
  if (tier === 'none') return 'border-farm-danger bg-farm-danger text-white';
  if (tier === 'view') return 'border-amber-500 bg-amber-500 text-white';
  return 'border-farm-green bg-farm-green text-white';
}

export function ModuleAccessDialog({companyId, userId, userName, open, onClose}: Props) {
  const {notify} = useToast();
  const [catalog, setCatalog] = useState<ModuleOption[] | null>(null);
  const [selections, setSelections] = useState<AccessSelections>({});
  const [tiers, setTiers] = useState<AccessSelections>({});
  const [busy, setBusy] = useState<string | null>(null);

  const reload = () => {
    setCatalog(null); setSelections({}); setTiers({});
    moduleAccessApi.catalog()
      .then(async (mods) => {
        setCatalog(mods);
        const next: AccessSelections = {};
        for (const m of mods) {
          const t = await moduleAccessApi.tier(companyId, userId, m.module);
          next[m.module] = t;
        }
        setTiers(next);
        // selections default to current tier (so the user only opts in/out for specific toggles)
        setSelections({...next});
      })
      .catch((e) => notify(e instanceof Error ? e.message : 'Failed to load module access', 'error'));
  };

  useEffect(() => {if (open) reload(); /* eslint-disable-line react-hooks/exhaustive-deps */}, [open, companyId, userId]);

  const dirty = useMemo(() => Object.keys(selections).some((k) => selections[k] !== tiers[k]), [selections, tiers]);

  async function apply() {
    setBusy('apply');
    try {
      const changes = catalog?.filter((m) => selections[m.module] !== tiers[m.module]) ?? [];
      for (const m of changes) await moduleAccessApi.apply(companyId, userId, m, selections[m.module]!);
      if (changes.length > 0) notify(`Updated ${changes.length} module${changes.length === 1 ? '' : 's'} for ${userName}`);
      else notify('No changes to save');
      onClose();
    } catch (e) {
      notify(e instanceof Error ? e.message : 'Update failed', 'error');
    } finally { setBusy(null); }
  }

  return (
    <Dialog.Root open={open} onOpenChange={(o) => {if (!o) onClose();}}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-40 bg-black/40" />
        <Dialog.Content className="fixed left-1/2 top-1/2 z-50 max-h-[88vh] w-[94vw] max-w-2xl -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-2xl bg-farm-card p-6 shadow-xl">
          <div className="mb-1 flex items-start justify-between">
            <div>
              <Dialog.Title className="flex items-center gap-2 text-xl font-bold text-farm-green">
                <ShieldCheck className="h-5 w-5" aria-hidden /> Module access — {userName}
              </Dialog.Title>
              <p className="mt-1 text-sm text-farm-muted">
                Each module gets a tier. <strong>Not Visible</strong> hides it; <strong>View-only</strong> lets them see records; <strong>Edit & Manage</strong> gives full actions.
                Saves queue one or two key-level overrides per changed module.
              </p>
            </div>
            <Dialog.Close className="rounded p-1 text-farm-muted hover:text-farm-ink" aria-label="Close"><X size={20} aria-hidden /></Dialog.Close>
          </div>

          {catalog === null ? (
            <p className="py-4 text-sm text-farm-muted">Loading…</p>
          ) : catalog.length === 0 ? (
            <EmptyState title="No modules to configure" hint="Add permissions catalog entries first." />
          ) : (
            <ul className="mt-3 divide-y divide-farm-accent-soft">
              {catalog.map((m) => {
                const current = selections[m.module] ?? 'none';
                return (
                  <li key={m.module} className="grid grid-cols-1 items-center gap-2 py-3 sm:grid-cols-[140px_1fr]">
                    <div>
                      <p className="text-sm font-bold uppercase text-farm-ink">{m.module}</p>
                      <p className="text-[11px] text-farm-muted">{m.keys.length} keys</p>
                    </div>
                    <div className="flex flex-wrap gap-1.5">
                      {TIERS.map((t) => {
                        const Icon = t.icon;
                        return (
                          <button key={t.tier} type="button"
                            onClick={() => setSelections((s) => ({...s, [m.module]: t.tier}))}
                            aria-pressed={current === t.tier}
                            className={`flex items-center gap-1 rounded-full border px-2.5 py-1 text-[11px] font-bold ${colorFor(t.tier, current)}`}>
                            <Icon className="h-3 w-3" aria-hidden /> {t.label}
                          </button>
                        );
                      })}
                      <details className="ml-1">
                        <summary className="cursor-pointer list-none text-[11px] text-farm-muted hover:text-farm-ink">
                          <ChevronDown className="inline h-3 w-3" /> keys
                        </summary>
                        <ul className="ml-3 mt-1 space-y-0.5 text-[10px] text-farm-muted">
                          {m.keys.map((k) => <li key={k}>{k}</li>)}
                        </ul>
                      </details>
                    </div>
                  </li>
                );
              })}
            </ul>
          )}

          <div className="mt-5 flex items-center justify-between border-t border-farm-accent-soft pt-4">
            <p className="text-xs text-farm-muted">{dirty ? 'Pending changes shown above' : 'No pending changes'}</p>
            <div className="flex gap-2">
              <Button variant="secondary" onClick={onClose} disabled={busy !== null}>Close</Button>
              <Button onClick={apply} disabled={busy !== null || !dirty}>
                {busy ? 'Saving…' : 'Save changes'}
              </Button>
            </div>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
