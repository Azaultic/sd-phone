import { useTheme } from '@/stores/themeStore';
import { t } from '@/i18n';

interface Props {
    onGoHome?: () => void;
    closing?: boolean;
}

export function HomeIndicator({ onGoHome, closing = false }: Props) {
    const { theme, statusLightOverride, homeAutoLight } = useTheme('theme', 'statusLightOverride', 'homeAutoLight');
    const interactive = Boolean(onGoHome) && !closing;
    const lightPill = statusLightOverride ?? homeAutoLight ?? (theme === 'dark');
    const pillColor = lightPill
        ? 'bg-white/75 group-hover:bg-white/90'
        : 'bg-black/70 group-hover:bg-black/85';

    return (
        <div
            className={`group absolute inset-x-0 bottom-0 z-[55] flex justify-center pb-[5px] transition-opacity duration-200 ${
                closing ? 'opacity-0' : 'opacity-100'
            } ${interactive ? 'cursor-pointer' : ''}`}
            style={{ height: 21, pointerEvents: interactive ? 'auto' : 'none' }}
            onClick={interactive ? onGoHome : undefined}
            role={interactive ? 'button' : undefined}
            aria-label={interactive ? t('shell.goToHomeScreen','Go to Home Screen') : undefined}
        >
            <div
                className={`h-[5px] w-[134px] rounded-full transition-all duration-200 ${pillColor} ${
                    interactive ? 'group-hover:-translate-y-[2px]' : ''
                }`}
            />
        </div>
    );
}
