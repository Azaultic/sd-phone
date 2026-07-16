
export const COLS = 5;
export const ROWS = 6;

export type Cell = 'empty' | 'tbd' | 'correct' | 'present' | 'absent';

export const RANK: Record<Cell, number> = { empty: 0, tbd: 0, absent: 1, present: 2, correct: 3 };

export const KEY_ROWS: string[][] = [
    'QWERTYUIOP'.split(''),
    'ASDFGHJKL'.split(''),
    ['ENTER', ...'ZXCVBNM'.split(''), 'BACK'],
];

export function scoreGuess(guess: string, answer: string): Cell[] {
    const res: Cell[] = Array(COLS).fill('absent');
    const counts: Record<string, number> = {};
    for (const ch of answer) counts[ch] = (counts[ch] ?? 0) + 1;

    for (let i = 0; i < COLS; i++) {
        if (guess[i] === answer[i]) { res[i] = 'correct'; counts[guess[i]]--; }
    }
    for (let i = 0; i < COLS; i++) {
        if (res[i] === 'correct') continue;
        const ch = guess[i];
        if ((counts[ch] ?? 0) > 0) { res[i] = 'present'; counts[ch]--; }
    }
    return res;
}
