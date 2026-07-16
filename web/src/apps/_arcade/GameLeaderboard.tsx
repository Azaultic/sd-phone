import { Crown } from 'lucide-react';

export const MEDALS = ['#E8B923', '#AEB4BD', '#CD7F32'];

interface LeaderboardRowProps {
    rank: number;
    name: string;
    value: string | number;
    highlight: boolean;
    track: string;
    accent: string;
    text: string;
    muted: string;
}

export function LeaderboardRow({ rank, name, value, highlight, track, accent, text, muted }: LeaderboardRowProps) {
    const top = rank <= 3;
    return (
        <div className="flex items-center gap-3 rounded-2xl px-3 py-2.5" style={{ backgroundColor: highlight ? accent : track }}>
            <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-[13px] font-extrabold" style={{ backgroundColor: top ? MEDALS[rank - 1] : muted, color: '#fff' }}>
                {rank === 1 ? <Crown className="h-[14px] w-[14px]" strokeWidth={2.5} /> : rank}
            </span>
            <span className="min-w-0 flex-1 truncate text-[15px] font-bold" style={{ color: highlight ? '#fff' : text }}>{name}</span>
            <span className="shrink-0 text-[14px] font-extrabold tabular-nums" style={{ color: highlight ? '#fff' : accent }}>{value}</span>
        </div>
    );
}
