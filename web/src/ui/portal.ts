import { createPortal } from 'react-dom';
import type { ReactNode } from 'react';

export function portalToPhoneScreen(node: ReactNode): ReactNode {
    const root = typeof document !== 'undefined'
        ? (document.querySelector('[data-phone-screen]') as HTMLElement | null)
        : null;
    return root ? createPortal(node, root) : node;
}
