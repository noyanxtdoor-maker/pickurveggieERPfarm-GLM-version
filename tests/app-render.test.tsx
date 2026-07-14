// @vitest-environment jsdom
// Smoke test: the V3 app actually mounts — providers init, the router renders, and a real screen (Login) paints
// with its components, all in mock mode (no cloud). Validates route + component + provider initialization.
import 'fake-indexeddb/auto';
import {describe, expect, it} from 'vitest';
import {render, screen, waitFor} from '@testing-library/react';
import App from '@/app/App';

describe('V3 application renders', () => {
  it('mounts providers + router and shows the login screen (mock mode)', async () => {
    render(<App />);
    // P1 redesign (2026-07-15): dark theme + Email/Username field; the submit button is now "Sign In"
    // (was "Log in to ERP") — so /sign in/i now matches BOTH the tab toggle AND the submit button (use All).
    await waitFor(() => expect(screen.getAllByText(/Pick Ur Veggie/i).length).toBeGreaterThan(0), {timeout: 4000});
    expect(screen.getAllByRole('button', {name: /sign in/i}).length).toBeGreaterThan(0);
    expect(screen.getByRole('button', {name: /create pos account/i})).toBeDefined();
    // The redesign's defining element: the sign-in form accepts email OR username.
    expect(screen.getByLabelText(/email \/ username/i)).toBeDefined();
  });
});
