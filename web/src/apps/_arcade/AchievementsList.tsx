import { Check, Lock, Trophy } from 'lucide-react';

interface ArcadeAchievement {
    id: string;
    name: string;
    desc: string;
}

interface AchievementsListProps {
    items: ArcadeAchievement[];
    unlocked: string[];
    track: string;
    accent: string;
    text: string;
    sub: string;
    muted: string;
}

export function AchievementsList({ items, unlocked, track, accent, text, sub, muted }: AchievementsListProps) {
    return (
        <>
            {items.map(a => {
                const got = unlocked.includes(a.id);
                return (
                    <div key={a.id} className="flex items-center gap-3 rounded-2xl px-3 py-2.5" style={{ backgroundColor: track, opacity: got ? 1 : 0.6 }}>
                        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl" style={{ backgroundColor: got ? accent : muted }}>
                            <Trophy className="h-[18px] w-[18px] text-white" strokeWidth={2.4} />
                        </span>
                        <div className="min-w-0 flex-1">
                            <div className="text-[15px] font-bold" style={{ color: text }}>{a.name}</div>
                            <div className="text-[12px]" style={{ color: sub }}>{a.desc}</div>
                        </div>
                        {got
                            ? <Check className="h-[18px] w-[18px] shrink-0" strokeWidth={3} style={{ color: accent }} />
                            : <Lock  className="h-[15px] w-[15px] shrink-0" strokeWidth={2.4} style={{ color: sub }} />}
                    </div>
                );
            })}
        </>
    );
}
