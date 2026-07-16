import { create } from 'zustand';


export type TimerStatus = 'idle' | 'running' | 'paused' | 'finished';

interface TimerState {
    status:      TimerStatus;
    endsAt:      number;
    remainingMs: number;
    totalSecs:   number;
}

const useTimerStore = create<TimerState>(() => ({
    status: 'idle',
    endsAt: 0,
    remainingMs: 0,
    totalSecs: 0,
}));

export function tmRemainingMs(): number {
    const { status, endsAt, remainingMs } = useTimerStore.getState();
    if (status === 'running') return Math.max(0, endsAt - Date.now());
    if (status === 'paused')  return remainingMs;
    return 0;
}

export function tmStart(secs: number) {
    if (secs <= 0) return;
    useTimerStore.setState({ totalSecs: secs, endsAt: Date.now() + secs * 1000, remainingMs: 0, status: 'running' });
}
export function tmPause() {
    const { status, endsAt } = useTimerStore.getState();
    if (status !== 'running') return;
    useTimerStore.setState({ remainingMs: Math.max(0, endsAt - Date.now()), status: 'paused' });
}
export function tmResume() {
    const { status, remainingMs } = useTimerStore.getState();
    if (status !== 'paused') return;
    useTimerStore.setState({ endsAt: Date.now() + remainingMs, remainingMs: 0, status: 'running' });
}
export function tmFinish() {
    const { status } = useTimerStore.getState();
    if (status === 'idle' || status === 'finished') return;
    useTimerStore.setState({ status: 'finished', endsAt: 0, remainingMs: 0 });
}
export function tmCancel() {
    useTimerStore.setState({ status: 'idle', endsAt: 0, remainingMs: 0, totalSecs: 0 });
}

export function useTimer(): { status: TimerStatus; endsAt: number; totalSecs: number } {
    const status    = useTimerStore(s => s.status);
    const endsAt    = useTimerStore(s => s.endsAt);
    const totalSecs = useTimerStore(s => s.totalSecs);
    return { status, endsAt, totalSecs };
}
