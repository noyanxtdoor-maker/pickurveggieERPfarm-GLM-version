// Login / Create POS Account (P1A/P1B — owner-requested split-panel layout, 2026-07-10 screenshots).
// LEFT: marketing panel. RIGHT: SIGN IN | CREATE POS ACCOUNT tabs. Signup carries a REQUESTED role
// (a wish in auth metadata — grants nothing; the Approvals queue shows it and the admin assigns the real
// role, C2 §3). Email+password via Supabase Auth (identity is cloud-real, unlike a local username);
// self-service reset (B7 §2) + Google OAuth scaffold. Quick test identities appear in DEMO mode only.
import {useState} from 'react';
import {Navigate} from 'react-router-dom';
import {useForm} from 'react-hook-form';
import {z} from 'zod';
import {ShieldCheck, Workflow} from 'lucide-react';
import {useSession} from '../core/auth/session';
import {MOCK_MODE} from '../core/mock/mock';
import {Button} from '../components/ui';
import {Field, TextInput, zodResolver} from '../components/forms';

// Google OAuth provider icon (P1A Google scaffold; used on BOTH login + signup tabs — item 3).
function GoogleIcon() {
  return (
    <svg viewBox="0 0 48 48" className="h-4 w-4" aria-hidden>
      <path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3c-1.6 4.7-6 8-11.3 8-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.9 1.2 8 3.1l5.7-5.7C34.6 6.1 29.6 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.7-.4-3.5z" />
      <path fill="#FF3D00" d="M6.3 14.7l6.6 4.8C14.6 15.9 18.9 13 24 13c3.1 0 5.9 1.2 8 3.1l5.7-5.7C34.6 6.1 29.6 4 24 4 16.3 4 9.7 8.3 6.3 14.7z" />
      <path fill="#4CAF50" d="M24 44c5.5 0 10.4-2.1 14.1-5.6l-6.5-5.5C29.6 34.7 26.9 36 24 36c-5.3 0-9.7-3.3-11.3-8l-6.5 5C9.6 39.6 16.3 44 24 44z" />
      <path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.3-2.2 4.3-4.1 5.7l6.5 5.5C41.5 36 44 30.5 44 24c0-1.3-.1-2.7-.4-3.5z" />
    </svg>
  );
}

type Tab = 'signin' | 'signup';

const signinSchema = z.object({email: z.string().email('Enter a valid email'), password: z.string().min(1, 'Required')});
// B7 §2: minimum length ≥12, passphrase-friendly (no forced symbol rules)
const signupSchema = z.object({
  displayName: z.string().min(2, 'Enter your name'),
  email: z.string().email('Enter a valid email'),
  password: z.string().min(12, 'At least 12 characters — a short sentence works well'),
  requestedRole: z.string(),
});
const forgotSchema = z.object({email: z.string().email('Enter a valid email')});
type SigninInput = z.infer<typeof signinSchema>;
type SignupInput = z.infer<typeof signupSchema>;
type ForgotInput = z.infer<typeof forgotSchema>;

// The owner's 5-tier menu (screenshot). A REQUEST only — approval assigns the real role.
const ROLE_CHOICES = [
  {value: 'employee', label: 'Employee (POS, Payouts Review Only)'},
  {value: 'operator', label: 'Operator (POS, Input Payouts, Ledger entries)'},
  {value: 'admin', label: 'Admin (POS, Financial Statements, Core Ledgers, Setup)'},
  {value: 'co_owner', label: 'Co-Owner (All Access, Edit everything except DEV configurations)'},
  {value: 'owner', label: 'Owner (All Access, Appoint Admins/Employees)'},
];

const QUICK_IDENTITIES = [
  {name: 'dev', sub: 'DEVELOPER', badge: 'D'},
  {name: 'owner', sub: 'FARM OWNER', badge: 'O'},
  {name: 'admin', sub: 'ADMINISTRATOR', badge: 'A'},
  {name: 'employee', sub: 'POS CASHIER', badge: 'E'},
];

export default function Login() {
  const {signIn, signUp, resetPassword, signInWithGoogle, configured, status} = useSession();
  const [tab, setTab] = useState<Tab>('signin');
  const [forgot, setForgot] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const si = useForm<SigninInput>({resolver: zodResolver(signinSchema)});
  const su = useForm<SignupInput>({resolver: zodResolver(signupSchema), defaultValues: {requestedRole: 'employee'}});
  const fo = useForm<ForgotInput>({resolver: zodResolver(forgotSchema)});

  if (status === 'authenticated') return <Navigate to="/dashboard" replace />;

  const switchTab = (t: Tab) => {setTab(t); setForgot(false); setError(null); setNotice(null);};

  const labelCls = 'mb-1.5 block text-[11px] font-black uppercase tracking-wider text-farm-muted';

  return (
    <div className="flex min-h-screen bg-farm-bg">
      {/* LEFT — marketing panel (owner screenshot) */}
      <div className="hidden flex-col justify-between bg-farm-green p-10 text-white lg:flex lg:w-1/2">
        <div className="flex items-center gap-3">
          <span className="flex h-11 w-11 items-center justify-center rounded-xl bg-white/15 text-xl font-black">₱</span>
          <span>
            <span className="block text-lg font-extrabold leading-tight">Pick Ur Veggie</span>
            <span className="block text-[10px] font-black uppercase tracking-widest text-white/60">Agricultural ERP</span>
          </span>
        </div>
        <div>
          <h1 className="mb-5 text-5xl font-black leading-tight">
            Simplifying the <span className="text-white/50">numbers</span> of the farm harvest.
          </h1>
          <p className="max-w-md text-lg text-white/80">
            A robust, <strong className="text-white">offline-first</strong> enterprise manager combining touch-screen
            weighing Point-of-Sale, real-time consumable and equipment inventories, advanced ledgers, dynamic cash
            flows, and secure loans tracking.
          </p>
          <div className="mt-8 flex items-center gap-6 text-sm text-white/70">
            <span className="flex items-center gap-2"><ShieldCheck className="h-4 w-4" aria-hidden /> Role Enforcement</span>
            <span className="flex items-center gap-2"><Workflow className="h-4 w-4" aria-hidden /> Auto-sync Accounting</span>
          </div>
        </div>
        <p className="text-xs text-white/50">Pick Ur Veggie ERP v1.0.0 © 2026. Made with Developer Precision.</p>
      </div>

      {/* RIGHT — auth card */}
      <div className="flex flex-1 items-center justify-center p-6">
        <div className="w-full max-w-md rounded-2xl bg-farm-card p-8 shadow-xl">
          {/* tabs */}
          <div className="mb-6 flex border-b border-farm-accent-soft text-sm font-black uppercase tracking-wider">
            <button onClick={() => switchTab('signin')} className={tab === 'signin' ? 'border-b-2 border-farm-green px-4 pb-3 text-farm-ink' : 'px-4 pb-3 text-farm-muted hover:text-farm-ink'}>Sign In</button>
            <button onClick={() => switchTab('signup')} className={tab === 'signup' ? 'border-b-2 border-farm-green px-4 pb-3 text-farm-ink' : 'px-4 pb-3 text-farm-muted hover:text-farm-ink'}>Create POS Account</button>
          </div>

          {MOCK_MODE ? (
            <p className="mb-4 rounded-lg bg-farm-accent-soft px-3 py-2 text-sm text-farm-green">
              Demo mode — no cloud needed. Sign in with any email &amp; password to explore the app.
            </p>
          ) : !configured ? (
            <p className="mb-4 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">
              Supabase is not configured. Set <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code>.
            </p>
          ) : null}
          {notice ? <p className="mb-4 rounded-lg bg-farm-accent-soft px-3 py-2 text-sm font-semibold text-farm-green" role="status">{notice}</p> : null}

          {tab === 'signin' && !forgot ? (
            <form className="space-y-4" onSubmit={si.handleSubmit(async (v) => {
              setError(null);
              const res = await signIn(v.email, v.password);
              if (res.error) setError(res.error);
            })}>
              <div>
                <label className={labelCls} htmlFor="email">Email</label>
                <TextInput id="email" type="email" autoComplete="username" placeholder="e.g. maria@farm.com" {...si.register('email')} />
                {si.formState.errors.email ? <p className="mt-1 text-xs text-red-700">{si.formState.errors.email.message}</p> : null}
              </div>
              <div>
                <label className={labelCls} htmlFor="password">Password</label>
                <TextInput id="password" type="password" autoComplete="current-password" placeholder="••••••" {...si.register('password')} />
                {si.formState.errors.password ? <p className="mt-1 text-xs text-red-700">{si.formState.errors.password.message}</p> : null}
              </div>
              {error ? <p className="text-sm font-medium text-red-700" role="alert">{error}</p> : null}
              <Button type="submit" className="w-full uppercase tracking-wider" disabled={si.formState.isSubmitting || (!configured && !MOCK_MODE)}>Log in to ERP</Button>
              {!MOCK_MODE ? (
                <Button type="button" variant="secondary" className="w-full" disabled={!configured}
                  onClick={async () => {setError(null); const r = await signInWithGoogle(); if (r.error) setError(r.error.includes('not enabled') || r.error.includes('Unsupported') ? 'Google sign-in is not enabled yet — the owner switches it on in the Supabase dashboard (Phase_1_OAuth_Setup.md).' : r.error);}}>
                  <GoogleIcon /> Continue with Google
                </Button>
              ) : null}
              <button type="button" className="w-full text-sm text-farm-muted underline" onClick={() => {setForgot(true); setError(null); setNotice(null);}}>Forgot password?</button>
            </form>
          ) : tab === 'signin' && forgot ? (
            <form className="space-y-4" onSubmit={fo.handleSubmit(async (v) => {
              setError(null);
              const res = await resetPassword(v.email);
              if (res.error) {setError(res.error); return;}
              setForgot(false);
              setNotice('Check your email for the reset link — it opens a page where you set a new password.');
            })}>
              <p className="text-sm text-farm-muted">Enter your account email and we will send a password-reset link.</p>
              <div>
                <label className={labelCls} htmlFor="fo-email">Email</label>
                <TextInput id="fo-email" type="email" autoComplete="username" {...fo.register('email')} />
                {fo.formState.errors.email ? <p className="mt-1 text-xs text-red-700">{fo.formState.errors.email.message}</p> : null}
              </div>
              {error ? <p className="text-sm font-medium text-red-700" role="alert">{error}</p> : null}
              <Button type="submit" className="w-full" disabled={fo.formState.isSubmitting || (!configured && !MOCK_MODE)}>Send reset link</Button>
              <button type="button" className="w-full text-sm text-farm-muted underline" onClick={() => setForgot(false)}>Back to sign in</button>
            </form>
          ) : (
            <form className="space-y-4" onSubmit={su.handleSubmit(async (v) => {
              setError(null);
              const res = await signUp(v.email, v.password, v.displayName, v.requestedRole);
              if (res.error) {setError(res.error); return;}
              switchTab('signin');
              setNotice(res.needsConfirmation
                ? 'Almost there — confirm your email via the link we sent, then sign in. An admin will approve your access.'
                : 'Account created. An admin will approve your access shortly.');
            })}>
              <div>
                <label className={labelCls} htmlFor="su-name">Your name</label>
                <TextInput id="su-name" autoComplete="name" placeholder="e.g. Maria" {...su.register('displayName')} />
                {su.formState.errors.displayName ? <p className="mt-1 text-xs text-red-700">{su.formState.errors.displayName.message}</p> : null}
              </div>
              <div>
                <label className={labelCls} htmlFor="su-email">Email</label>
                <TextInput id="su-email" type="email" autoComplete="username" {...su.register('email')} />
                {su.formState.errors.email ? <p className="mt-1 text-xs text-red-700">{su.formState.errors.email.message}</p> : null}
              </div>
              <div>
                <label className={labelCls} htmlFor="su-password">Password</label>
                <TextInput id="su-password" type="password" autoComplete="new-password" {...su.register('password')} />
                {su.formState.errors.password ? <p className="mt-1 text-xs text-red-700">{su.formState.errors.password.message}</p> : null}
              </div>
              <div>
                <label className={labelCls} htmlFor="su-role">Select role permission</label>
                <select id="su-role" {...su.register('requestedRole')} className="min-h-12 w-full rounded-lg border border-farm-accent-soft bg-farm-bg px-3 text-sm font-semibold">
                  {ROLE_CHOICES.map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
                </select>
                <p className="mt-1 text-[11px] text-farm-muted">*Note: creating an account with higher roles requires strict approval from the current platform owners before logging in.</p>
              </div>
              {error ? <p className="text-sm font-medium text-red-700" role="alert">{error}</p> : null}
              <Button type="submit" className="w-full uppercase tracking-wider" disabled={su.formState.isSubmitting || (!configured && !MOCK_MODE)}>Register POS Account</Button>
              {/* Item 3 (2026-07-14): Google sign-in on the SIGNUP tab too, not just login — same hook, same
                  graceful "not enabled" message. A Google signup creates the auth identity + triggers
                  handle_new_auth_user() the same way email signup does; the account lands in the Approvals
                  queue pending appointment (no self-granted role). */}
              {!MOCK_MODE ? (
                <Button type="button" variant="secondary" className="w-full" disabled={!configured}
                  onClick={async () => {setError(null); const r = await signInWithGoogle(); if (r.error) setError(r.error.includes('not enabled') || r.error.includes('Unsupported') ? 'Google sign-in is not enabled yet — the owner switches it on in the Supabase dashboard (Phase_1_OAuth_Setup.md).' : r.error);}}>
                  <GoogleIcon /> Continue with Google
                </Button>
              ) : null}
            </form>
          )}

          {/* Quick test identities — DEMO MODE ONLY (any credentials work there) */}
          {MOCK_MODE ? (
            <div className="mt-6 border-t border-farm-accent-soft pt-4">
              <div className="mb-2 flex items-center justify-between">
                <span className="text-[11px] font-black uppercase tracking-wider text-farm-muted">Quick test identities:</span>
                <span className="rounded bg-farm-accent-soft px-1.5 py-0.5 text-[9px] font-black uppercase text-farm-green">Offline seeding</span>
              </div>
              <div className="grid grid-cols-2 gap-2">
                {QUICK_IDENTITIES.map((q) => (
                  <button key={q.name} onClick={async () => {setError(null); await signIn(`${q.name}@demo.local`, 'demo');}}
                    className="flex items-center justify-between rounded-xl border border-farm-accent-soft bg-farm-bg px-3 py-2 text-left hover:border-farm-green">
                    <span>
                      <span className="block text-sm font-bold text-farm-ink">{q.name}</span>
                      <span className="block text-[9px] font-black uppercase tracking-wider text-farm-muted">{q.sub}</span>
                    </span>
                    <span className="flex h-6 w-6 items-center justify-center rounded-full bg-farm-green text-[10px] font-black text-white">{q.badge}</span>
                  </button>
                ))}
              </div>
            </div>
          ) : null}
        </div>
      </div>
    </div>
  );
}
