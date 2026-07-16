import { Smartphone } from 'lucide-react';

import { t } from '@/i18n';
import { ListGroup, ListRow, ToggleRow } from '@/ui/ListGroup';
import { SubPage } from '../SettingsSubPage';

export function SoftwareUpdatePage({ onBack }: { onBack: () => void }) {
    return (
        <SubPage title={t('settings.softwareUpdate', 'Software Update')} onBack={onBack}>
            <div className="mx-4 flex flex-col items-center gap-3 overflow-hidden rounded-[10px] bg-white px-4 py-6">
                <div className="flex h-[64px] w-[64px] items-center justify-center rounded-[14px] bg-ios-blue shadow-md">
                    <Smartphone className="h-9 w-9 text-white" strokeWidth={1.75} />
                </div>
                <div className="text-center">
                    <div className="text-[17px] font-semibold text-black">iOS 18.4.1</div>
                    <div className="mt-0.5 text-[13px] text-ios-gray">{t('settings.softwareUpToDate', 'Your software is up to date.')}</div>
                </div>
                <div className="text-[12px] text-ios-gray">{t('settings.softwareLastChecked', 'Last checked: Today at 20:22')}</div>
            </div>

            <ListGroup
                footer={t('settings.autoUpdatesFooter', 'Automatic updates allow your phone to download and install updates overnight when connected to power.')}
            >
                <ToggleRow label={t('settings.automaticUpdates', 'Automatic Updates')} defaultOn divider />
                <ListRow   label={t('settings.customizeAutomaticUpdates', 'Customize Automatic Updates')} />
            </ListGroup>
        </SubPage>
    );
}
