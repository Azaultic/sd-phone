import { ChevronRight } from 'lucide-react';

import { getProfile } from '../data';

export function ProfileCard({ onPress }: { onPress?: () => void }) {
    const profile = getProfile();
    return (
        <button
            type="button"
            onClick={onPress}
            className="mx-4 mt-3 flex w-[calc(100%-2rem)] items-center gap-3 overflow-hidden rounded-[10px] bg-[#e5e5e5] dark:bg-[#1C1C1E] px-3 py-3 text-left active:bg-black/5 dark:active:bg-white/5"
        >
            <div
                className="flex h-[60px] w-[60px] shrink-0 items-center justify-center rounded-full text-[24px] font-semibold text-white shadow-sm"
                style={{ background: `linear-gradient(135deg, ${profile.avatar} 0%, ${shade(profile.avatar, -20)} 100%)` }}
            >
                {profile.initials}
            </div>
            <div className="min-w-0 flex-1">
                <div className="truncate text-[20px] font-semibold text-black dark:text-white">{profile.name}</div>
                <div className="truncate text-[13px] font-normal text-ios-gray">{profile.subtitle}</div>
            </div>
            <ChevronRight className="h-[17px] w-[17px] shrink-0 text-ios-gray3" strokeWidth={2.5} />
        </button>
    );
}

function shade(hex: string, amt: number): string {
    const v = hex.replace('#', '');
    if (v.length !== 6) return hex;
    const c = (i: number) => Math.max(0, Math.min(255, parseInt(v.slice(i, i + 2), 16) + amt));
    return `#${c(0).toString(16).padStart(2, '0')}${c(2).toString(16).padStart(2, '0')}${c(4).toString(16).padStart(2, '0')}`;
}
