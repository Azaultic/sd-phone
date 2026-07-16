import { useMemo } from 'react';

import {
    dayKey, isSameDay, MONTH_NAMES, monthGrid, WEEKDAY_SHORT,
} from './data';
import type { CalEvent } from './data';

interface Props {
    month:    Date;
    today:    Date;
    selected: Date;
    events:   CalEvent[];
    onPick:   (d: Date) => void;
}

export function MonthGrid({ month, today, selected, events, onPick }: Props) {
    const cells = useMemo(() => monthGrid(month), [month]);
    const monthIdx = month.getMonth();

    const eventsByDay = useMemo(() => {
        const map = new Map<string, CalEvent[]>();
        for (const ev of events) {
            const list = map.get(ev.dayKey) ?? [];
            list.push(ev);
            map.set(ev.dayKey, list);
        }
        return map;
    }, [events]);

    return (
        <div className="px-3 pb-4">
            <h2 className="px-3 pb-2 pt-3 text-[22px] font-bold text-ios-red">
                {MONTH_NAMES[monthIdx]} <span className="font-normal text-black dark:text-white">{month.getFullYear()}</span>
            </h2>

            <div className="grid grid-cols-7 px-2 pb-1">
                {WEEKDAY_SHORT.map((d, i) => (
                    <div key={i} className="text-center text-[12px] font-normal text-ios-gray">
                        {d}
                    </div>
                ))}
            </div>

            <div className="grid grid-cols-7 gap-y-1 px-2">
                {cells.map(d => {
                    const inMonth   = d.getMonth() === monthIdx;
                    const isToday   = isSameDay(d, today);
                    const isPicked  = isSameDay(d, selected);
                    const dots      = eventsByDay.get(dayKey(d)) ?? [];

                    return (
                        <button
                            key={d.getTime()}
                            type="button"
                            onClick={() => onPick(d)}
                            className="flex flex-col items-center justify-start py-1 active:opacity-60"
                            style={{ minHeight: 44 }}
                        >
                            <span
                                className="flex items-center justify-center rounded-full"
                                style={{
                                    width:    28,
                                    height:   28,
                                    fontSize: 18,
                                    fontWeight: isToday ? 600 : 400,
                                    color:      isPicked
                                                    ? (isToday ? '#ffffff' : '#ffffff')
                                                    : isToday
                                                        ? '#ff453a'
                                                        : inMonth ? undefined : '#8e8e93',
                                    background: isPicked
                                                    ? (isToday ? '#ff453a' : '#3a3a3c')
                                                    : 'transparent',
                                }}
                            >
                                {d.getDate()}
                            </span>
                            <div className="mt-0.5 flex h-[5px] items-center gap-[2px]">
                                {dots.slice(0, 3).map((ev, i) => (
                                    <span
                                        key={i}
                                        className="block rounded-full"
                                        style={{ width: 4, height: 4, background: ev.color }}
                                    />
                                ))}
                            </div>
                        </button>
                    );
                })}
            </div>
        </div>
    );
}
