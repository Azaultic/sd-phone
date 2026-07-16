import { Trophy } from 'lucide-react';

interface GameStat {
    label: string;
    value: number;
    highlight?: boolean;
}

interface GameOverCardProps {
    title: string;
    accent: string;
    sub: string;
    ink: string;
    cardBg: string;
    cardShadow: string;
    pop: string;
    stats: GameStat[];
    statSize?: number;
    newBest: boolean;
    newBestLabel: string;
    playAgainLabel: string;
    playAgainColor: string;
    onPlayAgain: () => void;
    children?: React.ReactNode;
}

export function GameOverCard({
    title, accent, sub, ink, cardBg, cardShadow, pop,
    stats, statSize = 32, newBest, newBestLabel,
    playAgainLabel, playAgainColor, onPlayAgain, children,
}: GameOverCardProps) {
    return (
        <div
            className="flex flex-col items-center rounded-[22px] px-8 py-6"
            style={{ background: cardBg, boxShadow: cardShadow, animation: pop }}
        >
            <div className="text-[15px] font-bold uppercase tracking-wide" style={{ color: accent }}>{title}</div>
            <div className="mt-2 flex items-center gap-7">
                {stats.map(s => (
                    <div key={s.label} className="flex flex-col items-center">
                        <span className="font-black leading-none tabular-nums" style={{ fontSize: statSize, color: s.highlight ? accent : ink }}>{s.value}</span>
                        <span className="mt-1 text-[11px] font-semibold uppercase tracking-wide" style={{ color: sub }}>{s.label}</span>
                    </div>
                ))}
            </div>
            {newBest && (
                <div className="mt-2.5 flex items-center gap-1 text-[12px] font-bold" style={{ color: accent }}>
                    <Trophy className="h-[13px] w-[13px]" strokeWidth={2.6} /> {newBestLabel}
                </div>
            )}
            {children}
            <button
                type="button"
                onClick={(e) => { e.stopPropagation(); onPlayAgain(); }}
                className="mt-4 rounded-full px-9 py-2.5 text-[15px] font-bold text-white active:opacity-80"
                style={{ backgroundColor: playAgainColor }}
            >
                {playAgainLabel}
            </button>
        </div>
    );
}
