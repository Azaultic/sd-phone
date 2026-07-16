import { t } from '@/i18n';
import { ListGroup, ListRow } from '@/ui/ListGroup';
import { SubPage } from '../SettingsSubPage';

export function AboutPage({ onBack }: { onBack: () => void }) {
    return (
        <SubPage title={t('settings.about', 'About')} onBack={onBack}>
            <ListGroup>
                <ListRow label={t('settings.aboutName', 'Name')}         value="SD's Phone"       divider />
                <ListRow label={t('settings.aboutNetwork', 'Network')}      value="LifeInvader"      divider />
                <ListRow label={t('settings.aboutPhoneNumber', 'Phone Number')} value="+1 (555) 018-2749" />
            </ListGroup>

            <ListGroup>
                <ListRow label={t('settings.aboutSoftwareVersion', 'Software Version')} value="18.4.1"       divider />
                <ListRow label={t('settings.aboutModelName', 'Model Name')}       value="SD Phone Pro"  divider />
                <ListRow label={t('settings.aboutModelNumber', 'Model Number')}     value="SP-2024"       divider />
                <ListRow label={t('settings.aboutCapacity', 'Capacity')}         value="256 GB"        />
            </ListGroup>

            <ListGroup>
                <ListRow label={t('settings.aboutCarrier', 'Carrier')}          value="LifeInvader Wireless"  divider />
                <ListRow label={t('settings.aboutImei', 'IMEI')}             value="352 099 00 123456 2"   divider />
                <ListRow label={t('settings.aboutSerialNumber', 'Serial Number')}    value="C39ZX8NRPHR4"         />
            </ListGroup>

            <ListGroup>
                <ListRow label={t('settings.aboutLegalRegulatory', 'Legal & Regulatory')} />
            </ListGroup>
        </SubPage>
    );
}
