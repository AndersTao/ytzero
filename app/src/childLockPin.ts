import { clearChildLockFailures, isPinLocked, registerChildLockFailure } from "./childTime";
import { getSetting } from "./db";

/** The app-wide child lock PIN: six digits, set by the primary profile. */
export function isSixDigitPin(pin: unknown): pin is string {
  return typeof pin === "string" && /^\d{6}$/.test(pin);
}

export function isChildLockEnabled() {
  return getSetting("child_lock_enabled") === "1" && Boolean(getSetting("child_lock_pin_hash"));
}

export async function verifyChildLockPin(pin: string) {
  const hash = getSetting("child_lock_pin_hash");
  if (!hash) return false;
  return Bun.password.verify(pin, hash);
}

export type LeaveChildResult =
  | { ok: true }
  | { ok: false; pinRequired: true }
  | { ok: false; pinRequired: false; pinLocked: boolean };

/**
 * Leaving a child profile for another one needs the child lock PIN, like the
 * profile switch in the web client. No PIN at all is only a question (it does
 * not count as a wrong attempt); three wrong ones lock the child profile,
 * and while it is locked no PIN is tried at all.
 */
export async function checkLeavingChildProfile(
  current: { id: number; is_child: number } | null,
  targetId: number,
  pin: unknown,
): Promise<LeaveChildResult> {
  if (!current || current.id === targetId || current.is_child !== 1 || !isChildLockEnabled()) return { ok: true };
  // Locked after too many wrong PINs: no more guesses until the lock runs out.
  if (isPinLocked(current.id)) return { ok: false, pinRequired: false, pinLocked: true };
  if (pin === undefined || pin === null || pin === "") return { ok: false, pinRequired: true };
  if (!isSixDigitPin(pin) || !(await verifyChildLockPin(pin))) {
    await registerChildLockFailure(current.id);
    return { ok: false, pinRequired: false, pinLocked: isPinLocked(current.id) };
  }
  await clearChildLockFailures(current.id);
  return { ok: true };
}
