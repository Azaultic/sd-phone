import { useEffect, useRef } from 'react';

export function useDidEnter(ready = true): boolean {
    const didEnter = useRef(false);
    useEffect(() => {
        if (ready) didEnter.current = true;
    }, [ready]);
    return didEnter.current;
}
