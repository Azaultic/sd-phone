import { create } from 'zustand';


export interface Lap { index: number; lapMs: number; totalMs: number; }

interface StopwatchState {
    running:       boolean;
    startedAt:     number;
    accumulatedMs: number;
    lapBaseMs:     number;
    laps:          Lap[];
}

const useStopwatchStore = create<StopwatchState>(() => ({
    running: false,
    startedAt: 0,
    accumulatedMs: 0,
    lapBaseMs: 0,
    laps: [],
}));

export function swElapsed(): number {
    const { running, startedAt, accumulatedMs } = useStopwatchStore.getState();
    return accumulatedMs + (running && startedAt ? Date.now() - startedAt : 0);
}

export function swStart() {
    if (useStopwatchStore.getState().running) return;
    useStopwatchStore.setState({ startedAt: Date.now(), running: true });
}
export function swStop() {
    const { running, startedAt, accumulatedMs } = useStopwatchStore.getState();
    if (!running) return;
    useStopwatchStore.setState({ accumulatedMs: accumulatedMs + (Date.now() - startedAt), running: false, startedAt: 0 });
}
export function swLap() {
    const { running, laps, lapBaseMs } = useStopwatchStore.getState();
    if (!running) return;
    const total = swElapsed();
    useStopwatchStore.setState({
        laps: [...laps, { index: laps.length + 1, lapMs: total - lapBaseMs, totalMs: total }],
        lapBaseMs: total,
    });
}
export function swReset() {
    useStopwatchStore.setState({ running: false, startedAt: 0, accumulatedMs: 0, lapBaseMs: 0, laps: [] });
}

export function useStopwatch(): { running: boolean; laps: Lap[] } {
    const running = useStopwatchStore(s => s.running);
    const laps    = useStopwatchStore(s => s.laps);
    return { running, laps };
}
