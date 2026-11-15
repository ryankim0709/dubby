import { cleanup, render, screen, within } from '@testing-library/react';
import { afterEach, describe, expect, test } from 'vitest';
import App from './App';

afterEach(cleanup);

describe('page structure', (): void => {
  test('exposes banner, navigation, main, and footer landmarks', (): void => {
    render(<App />);

    expect(screen.getByRole('banner')).toBeTruthy();
    expect(screen.getByRole('navigation', { name: 'Main navigation' })).toBeTruthy();
    expect(screen.getByRole('main')).toBeTruthy();
    expect(screen.getByRole('contentinfo')).toBeTruthy();
  });

  test('has one h1, h2 sections, and h3 only inside the walkthrough panels', (): void => {
    render(<App />);

    const h1s = screen.getAllByRole('heading', { level: 1 });
    expect(h1s).toHaveLength(1);
    expect(h1s[0]?.textContent).toBe('Your voice.A new language.');

    const h2Names: string[] = screen
      .getAllByRole('heading', { level: 2 })
      .map((heading: HTMLElement): string => heading.textContent ?? '');
    expect(h2Names).toHaveLength(3);

    const levels: number[] = Array.from(document.querySelectorAll<HTMLElement>('h1, h2, h3')).map(
      (heading: HTMLElement): number => Number(heading.tagName.slice(1)),
    );
    levels.forEach((level: number, index: number): void => {
      const previous: number = levels[index - 1] ?? 0;
      expect(level - previous).toBeLessThanOrEqual(1);
    });
  });

  test('offers a skip link that targets the focusable main landmark', (): void => {
    render(<App />);

    const skip: HTMLElement = screen.getByRole('link', { name: 'Skip to content' });
    const main: HTMLElement = screen.getByRole('main');
    expect(skip.getAttribute('href')).toBe('#main');
    expect(main.id).toBe('main');
    expect(main.getAttribute('tabindex')).toBe('-1');
    expect(document.body.firstElementChild?.firstElementChild).toBe(skip);
  });

  test('states the audience and status without making availability claims', (): void => {
    render(<App />);

    const hero: HTMLElement = screen
      .getByRole('heading', { level: 1 })
      .closest('section') as HTMLElement;
    expect(within(hero).getByText(/In development for iPhone/)).toBeTruthy();
    expect(within(hero).getByText(/iOS 26 and later/)).toBeTruthy();
    expect(document.body.textContent).toMatch(/not available to download yet/i);
  });
});

describe('coaching copy', (): void => {
  test('separates written tips from measurements', (): void => {
    render(<App />);

    const section: HTMLElement = document.getElementById('coaching') as HTMLElement;
    expect(section.textContent).toMatch(/a tip is advice, not a measurement/);
    expect(section.textContent).toMatch(/not a pronunciation score/);
  });
});

describe('illustrations are labeled', (): void => {
  test('the hero illustration says it is not a recording', (): void => {
    render(<App />);

    const art: HTMLElement = screen.getByRole('group', {
      name: 'Illustration of a sample line and a sample waveform',
    });
    expect(art.hasAttribute('data-illustrative')).toBe(true);
    expect(within(art).getByText('Illustration · sample line, not a recording')).toBeTruthy();
  });

  test('the coaching diagram says nothing in it was measured', (): void => {
    render(<App />);

    const diagram: HTMLElement = document.querySelector('.lanes') as HTMLElement;
    expect(diagram.hasAttribute('data-illustrative')).toBe(true);
    expect(within(diagram).getByText('Illustrative diagram')).toBeTruthy();
    expect(within(diagram).getByText(/Nothing here was measured/)).toBeTruthy();
  });

  test('every illustrative figure on the page carries a visible label', (): void => {
    render(<App />);

    const figures: HTMLElement[] = Array.from(
      document.querySelectorAll<HTMLElement>('[data-illustrative]'),
    );
    expect(figures.length).toBeGreaterThanOrEqual(6);
    figures.forEach((figure: HTMLElement): void => {
      const label: string =
        figure.querySelector('.preview-label, .illustrative-label')?.textContent ?? '';
      expect(label).toMatch(/illustrat|example feedback/i);
    });
  });
});
