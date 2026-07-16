import { useEffect, useState } from 'react';

export { formatClockTime, formatLongDate } from '@/lib/time';

// Default is minute granularity: every current consumer renders HH:MM, so
// ticking each second meant 60x more re-renders than visible changes. The
// minute tick self-aligns to the wall-clock boundary (fires ~50ms after) so
// the displayed time never lags. Pass 'second' only where seconds are shown.
export function useClock(granularity: 'minute' | 'second' = 'minute'): Date {
    const [now, setNow] = useState<Date>(() => new Date());

    useEffect(() => {
        if (granularity === 'second') {
            const handle = window.setInterval(() => setNow(new Date()), 1000);
            return () => window.clearInterval(handle);
        }
        let handle: number;
        const arm = () => {
            const d = new Date();
            setNow(d);
            handle = window.setTimeout(arm, 60_050 - (d.getSeconds() * 1000 + d.getMilliseconds()));
        };
        arm();
        return () => window.clearTimeout(handle);
    }, [granularity]);

    return now;
}
