import type { ReactNode } from 'react';
import { Heart, House, Search, SquarePlus } from 'lucide-react';

import { AppBadge } from '@/shell/AppBadge';
import { t } from '@/i18n';

export type GTab = 'home' | 'search' | 'activity' | 'profile';

export function TabBar({ tab, onTab, onCreate, avatar, activityCount }: {
    tab:      GTab;
    onTab:    (tab: GTab) => void;
    onCreate: () => void;
    avatar?:  string;
    activityCount?: number;
}) {
    return (
        <div className="flex shrink-0 items-center justify-around border-t border-black/[0.08] bg-[#f2f2f2] pb-12 pt-3">
            <Btn label={t('photogram.home', 'Home')} onClick={() => onTab('home')}>
                <House className="h-[33px] w-[33px]" strokeWidth={tab === 'home' ? 2.5 : 1.9} fill="none" />
            </Btn>
            <Btn label={t('photogram.search', 'Search')} onClick={() => onTab('search')}>
                <Search className="h-[32px] w-[32px]" strokeWidth={tab === 'search' ? 2.8 : 2} />
            </Btn>
            <Btn label={t('photogram.create', 'Create')} onClick={onCreate}>
                <SquarePlus className="h-[33px] w-[33px]" strokeWidth={2} />
            </Btn>
            <Btn label={t('photogram.activity', 'Activity')} onClick={() => onTab('activity')}>
                <span className="relative">
                    <Heart className="h-[33px] w-[33px]" strokeWidth={tab === 'activity' ? 2.5 : 1.9} fill={tab === 'activity' ? 'currentColor' : 'none'} />
                    <AppBadge count={activityCount} small />
                </span>
            </Btn>
            <button type="button" aria-label={t('photogram.profile', 'Profile')} onClick={() => onTab('profile')} className="flex items-center justify-center active:opacity-50">
                {avatar
                    ? <img src={avatar} alt="" draggable={false} className={`h-[35px] w-[35px] rounded-full object-cover ${tab === 'profile' ? 'ring-[1.5px] ring-black ring-offset-1' : ''}`} />
                    : <span className={`h-[35px] w-[35px] rounded-full bg-black/15 ${tab === 'profile' ? 'ring-[1.5px] ring-black ring-offset-1' : ''}`} />}
            </button>
        </div>
    );
}

function Btn({ onClick, label, children }: { onClick: () => void; label: string; children: ReactNode }) {
    return (
        <button type="button" aria-label={label} onClick={onClick} className="flex items-center justify-center text-black active:opacity-50">
            {children}
        </button>
    );
}
