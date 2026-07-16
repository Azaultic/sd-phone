import { Newspaper, Inbox } from 'lucide-react';

import { TabBar, type TabBarItem } from '@/ui/TabBar';
import { t } from '@/i18n';

export type PagesTab = 'browse' | 'posts';

export function PagesTabBar({ tab, onChange }: { tab: PagesTab; onChange: (t: PagesTab) => void }) {
    const tabs: TabBarItem<PagesTab>[] = [
        { id: 'browse', label: t('pages.pages','Pages'),      icon: a => <Newspaper className="h-[33px] w-[33px]" strokeWidth={a ? 2.2 : 1.9} /> },
        { id: 'posts',  label: t('pages.yourPosts','Your Posts'), icon: a => <Inbox     className="h-[33px] w-[33px]" strokeWidth={a ? 2.2 : 1.9} /> },
    ];
    return <TabBar tabs={tabs} active={tab} onChange={onChange} />;
}
