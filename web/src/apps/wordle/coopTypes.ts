
import type { Cell } from './engine';

export interface CoopPlayer { id: string; name: string; you?: boolean; }

export interface Progress {
    rows:     Cell[][];
    guesses:  string[];
    solved:   boolean;
    failed:   boolean;
    tries:    number;
    finishMs: number;
}

export interface CoopState {
    phase:    'playing' | 'results';
    word:     string;
    startMs:  number;
    players:  CoopPlayer[];
    progress: Record<string, Progress>;
}

export function emptyProgress(): Progress {
    return { rows: [], guesses: [], solved: false, failed: false, tries: 0, finishMs: Infinity };
}

export function ranked(state: CoopState): { player: CoopPlayer; prog: Progress }[] {
    return state.players
        .map(player => ({ player, prog: state.progress[player.id] ?? emptyProgress() }))
        .sort((a, b) => {
            if (a.prog.solved !== b.prog.solved) return a.prog.solved ? -1 : 1;
            if (a.prog.solved) return a.prog.tries - b.prog.tries || a.prog.finishMs - b.prog.finishMs;
            return 0;
        });
}
