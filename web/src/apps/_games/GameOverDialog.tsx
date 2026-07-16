import { t } from '@/i18n';

interface GameOverDialogProps {
    title:            string;
    accent:           string;
    onPlayAgain?:     () => void;
    onReturnToLobby?: () => void;
    returnDisabled?:  boolean;
    onMenu:           () => void;
}

export function GameOverDialog({ title, accent, onPlayAgain, onReturnToLobby, returnDisabled, onMenu }: GameOverDialogProps) {
    return (
        <div className="absolute inset-0 z-30 flex items-center justify-center px-9" style={{ background: 'rgba(0,0,0,0.55)' }}>
            <div
                className="w-full max-w-[300px] rounded-[24px] p-5 text-center"
                style={{ background: '#26262B', boxShadow: '0 24px 60px rgba(0,0,0,0.6)', animation: 'game-over-pop 0.26s cubic-bezier(0.22,1,0.36,1)' }}
            >
                <div className="px-1 text-[20px] font-extrabold leading-tight text-white">{title}</div>
                <div className="mt-5 flex flex-col gap-2.5">
                    {onReturnToLobby && (
                        <>
                            <button type="button" disabled={returnDisabled} onClick={returnDisabled ? undefined : onReturnToLobby} className="w-full rounded-[14px] py-3 text-[16px] font-bold text-white active:opacity-80 disabled:opacity-40 disabled:active:opacity-40" style={{ background: accent }}>
                                {t('games.returnToLobby', 'Return to Lobby')}
                            </button>
                            {returnDisabled && <div className="-mt-0.5 text-[12px] font-medium text-white/45">{t('games.hostLeftLobby', 'Host left the lobby.')}</div>}
                        </>
                    )}
                    {onPlayAgain && (
                        <button type="button" onClick={onPlayAgain} className="w-full rounded-[14px] py-3 text-[16px] font-bold text-white active:opacity-80" style={{ background: accent }}>
                            {t('games.playAgain', 'Play again')}
                        </button>
                    )}
                    <button type="button" onClick={onMenu} className="w-full rounded-[14px] py-3 text-[16px] font-bold text-white/85 active:opacity-70" style={{ background: 'rgba(255,255,255,0.12)' }}>
                        {t('games.menu', 'Menu')}
                    </button>
                </div>
            </div>
            <style>{`@keyframes game-over-pop { 0% { transform: scale(0.86); opacity: 0; } 100% { transform: scale(1); opacity: 1; } }`}</style>
        </div>
    );
}
