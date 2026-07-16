import { useEffect, type Dispatch, type SetStateAction } from 'react';

export function useTapbackDismiss(pickerId: string | null, setPickerId: Dispatch<SetStateAction<string | null>>) {
    useEffect(() => {
        if (!pickerId) return;
        const onDown = (e: MouseEvent) => {
            if (!(e.target as HTMLElement).closest('.tapback-picker')) setPickerId(null);
        };
        document.addEventListener('mousedown', onDown);
        return () => document.removeEventListener('mousedown', onDown);
    }, [pickerId, setPickerId]);
}
