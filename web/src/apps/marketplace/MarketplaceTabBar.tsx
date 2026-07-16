import { House, Inbox } from 'lucide-react';

import { TabBar, type TabBarItem } from '@/ui/TabBar';
import { t } from '@/i18n';

export type MarketTab = 'home' | 'posts';

export function MarketplaceTabBar({ tab, onChange }: { tab: MarketTab; onChange: (t: MarketTab) => void }) {
    const tabs: TabBarItem<MarketTab>[] = [
        { id: 'home',  label: t('marketplace.home','Home'),       icon: a => <House className="h-[33px] w-[33px]" strokeWidth={a ? 2.2 : 1.9} /> },
        { id: 'posts', label: t('marketplace.yourPosts','Your Posts'), icon: a => <Inbox className="h-[33px] w-[33px]" strokeWidth={a ? 2.2 : 1.9} /> },
    ];
    return <TabBar tabs={tabs} active={tab} onChange={onChange} />;
}
