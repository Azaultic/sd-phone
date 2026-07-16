import { Home, Play, Search } from 'lucide-react';

import { t } from '@/i18n';
import { TabBar, type TabBarItem } from '@/ui/TabBar';

export type MusicTab = 'home' | 'library' | 'search';

export function MusicTabBar({ tab, onChange }: { tab: MusicTab; onChange: (t: MusicTab) => void }) {
    const tabs: TabBarItem<MusicTab>[] = [
        { id: 'home',    label: t('music.home', 'Home'),    icon: a => <Home   className="h-[30px] w-[30px]" strokeWidth={a ? 2.3 : 1.9} /> },
        { id: 'library', label: t('music.library', 'Library'), icon: a => <Play   className="h-[30px] w-[30px]" strokeWidth={a ? 2.1 : 1.9} fill={a ? 'currentColor' : 'none'} /> },
        { id: 'search',  label: t('music.search', 'Search'),  icon: a => <Search className="h-[30px] w-[30px]" strokeWidth={a ? 2.6 : 2.2} /> },
    ];
    return <TabBar tabs={tabs} active={tab} onChange={onChange} />;
}
