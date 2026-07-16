import { Copy, Images } from 'lucide-react';

import { TabBar, type TabBarItem } from '@/ui/TabBar';
import { t } from '@/i18n';

export type PhotosTab = 'gallery' | 'albums';

export function PhotoTabBar({ tab, onChange }: { tab: PhotosTab; onChange: (t: PhotosTab) => void }) {
    const tabs: TabBarItem<PhotosTab>[] = [
        { id: 'gallery', label: t('photos.gallery','Gallery'), icon: a => <Images className="h-[33px] w-[33px]" strokeWidth={a ? 2.2 : 1.9} /> },
        { id: 'albums',  label: t('photos.albums','Albums'),  icon: a => <Copy   className="h-[33px] w-[33px]" strokeWidth={a ? 2.2 : 1.9} /> },
    ];
    return <TabBar tabs={tabs} active={tab} onChange={onChange} />;
}
