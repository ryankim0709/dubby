import type { JSX } from 'react';

interface WaveformProps {
  readonly heights: readonly number[];
  readonly className?: string;
}

export function Waveform({ heights, className = '' }: WaveformProps): JSX.Element {
  return (
    <span className={`waveform ${className}`.trim()} aria-hidden="true">
      {heights.map((height: number, index: number): JSX.Element => (
        <i key={index} style={{ height: `${height}%` }} />
      ))}
    </span>
  );
}
