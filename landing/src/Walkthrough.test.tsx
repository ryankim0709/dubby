import { cleanup, render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { afterEach, describe, expect, test } from 'vitest';
import App from './App';
import { WALKTHROUGH_LABEL } from './content';

afterEach(cleanup);

const tab = (name: RegExp): HTMLElement => screen.getByRole('tab', { name });
const selected = (): string[] =>
  screen
    .getAllByRole('tab')
    .filter((node: HTMLElement): boolean => node.getAttribute('aria-selected') === 'true')
    .map((node: HTMLElement): string => node.id);

describe('walkthrough tabs', (): void => {
  test('uses tab semantics with a roving tabindex and one visible panel', (): void => {
    render(<App />);

    const list: HTMLElement = screen.getByRole('tablist', {
      name: 'Four steps of dubbing a scene',
    });
    const tabs: HTMLElement[] = within(list).getAllByRole('tab');
    expect(tabs).toHaveLength(4);
    expect(selected()).toEqual(['tab-lines']);
    expect(tabs.map((node: HTMLElement): string | null => node.getAttribute('tabindex'))).toEqual([
      '-1',
      '0',
      '-1',
      '-1',
    ]);

    const panel: HTMLElement = screen.getByRole('tabpanel');
    expect(panel.getAttribute('aria-labelledby')).toBe('tab-lines');
    expect(tab(/Make every line yours/).getAttribute('aria-controls')).toBe(panel.id);
    expect(within(panel).getByRole('heading', { level: 3 }).textContent).toBe(
      'Make every line yours.',
    );
  });

  test('a mouse click selects a step and shows its panel', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(tab(/Find your scene/));
    expect(selected()).toEqual(['tab-scene']);
    expect(within(screen.getByRole('tabpanel')).getByText('Choose a scene')).toBeTruthy();

    await user.click(tab(/Play it back/));
    expect(selected()).toEqual(['tab-replay']);
    expect(within(screen.getByRole('tabpanel')).getByText(/Saved to My Dubs/)).toBeTruthy();
    expect(
      within(screen.getByRole('tabpanel')).getByText(/Share with the iOS share sheet/),
    ).toBeTruthy();
  });

  test('arrow keys, Home, and End move focus and selection', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    tab(/Make every line yours/).focus();
    await user.keyboard('{ArrowDown}');
    expect(document.activeElement).toBe(tab(/Know what to work on/));
    expect(selected()).toEqual(['tab-coaching']);

    await user.keyboard('{End}');
    expect(document.activeElement).toBe(tab(/Play it back/));
    expect(selected()).toEqual(['tab-replay']);

    await user.keyboard('{ArrowDown}');
    expect(selected()).toEqual(['tab-replay']);

    await user.keyboard('{ArrowUp}');
    expect(selected()).toEqual(['tab-coaching']);

    await user.keyboard('{Home}');
    expect(document.activeElement).toBe(tab(/Find your scene/));
    expect(selected()).toEqual(['tab-scene']);

    await user.keyboard('{ArrowRight}');
    expect(selected()).toEqual(['tab-lines']);
    await user.keyboard('{ArrowLeft}');
    expect(selected()).toEqual(['tab-scene']);
  });

  test('Tab leaves the tablist for the active panel instead of the other tabs', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    tab(/Make every line yours/).focus();
    await user.tab();
    const panel: HTMLElement = screen.getByRole('tabpanel');
    expect(panel.contains(document.activeElement)).toBe(true);
    expect(document.activeElement?.textContent).toBe('Previous step');
  });

  test('Previous and Next step buttons work from the keyboard and stop at the ends', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(tab(/Find your scene/));
    const previous: HTMLElement = within(screen.getByRole('tabpanel')).getByRole('button', {
      name: 'Previous step',
    });
    expect(previous.getAttribute('aria-disabled')).toBe('true');
    await user.click(previous);
    expect(selected()).toEqual(['tab-scene']);

    const next: HTMLElement = within(screen.getByRole('tabpanel')).getByRole('button', {
      name: 'Next step',
    });
    next.focus();
    await user.keyboard('{Enter}');
    expect(selected()).toEqual(['tab-lines']);

    await user.click(tab(/Play it back/));
    const last: HTMLElement = within(screen.getByRole('tabpanel')).getByRole('button', {
      name: 'Next step',
    });
    expect(last.getAttribute('aria-disabled')).toBe('true');
    await user.click(last);
    expect(selected()).toEqual(['tab-replay']);
  });

  test('the live region stays quiet except after Previous and Next', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    const status: HTMLElement = screen.getByRole('status');
    expect(status.getAttribute('aria-live')).toBe('polite');
    expect(status.textContent).toBe('');

    await user.click(tab(/Find your scene/));
    await user.keyboard('{ArrowDown}');
    expect(status.textContent).toBe('');

    await user.click(
      within(screen.getByRole('tabpanel')).getByRole('button', { name: 'Next step' }),
    );
    expect(status.textContent).toBe('Step 3 of 4: Know what to work on.');

    await user.click(tab(/Find your scene/));
    expect(status.textContent).toBe('');
  });
});

describe('walkthrough honesty', (): void => {
  test('every step panel shows its preview with an illustrative label', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    for (const name of [
      /Find your scene/,
      /Make every line yours/,
      /Know what to work on/,
      /Play it back/,
    ]) {
      await user.click(tab(name));
      const figure: HTMLElement = within(screen.getByRole('tabpanel')).getByRole('figure');
      expect(figure.hasAttribute('data-illustrative')).toBe(true);
      expect(figure.textContent).toMatch(new RegExp(`${WALKTHROUGH_LABEL}|Example feedback`));
    }
  });

  test('coaching step is labeled Example feedback and shows no scores', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(tab(/Know what to work on/));
    const figure: HTMLElement = within(screen.getByRole('tabpanel')).getByRole('figure');
    expect(within(figure).getByText('Example feedback')).toBeTruthy();
    expect(figure.textContent).toMatch(/not a measured result/);
    expect(figure.textContent).not.toMatch(/\d|%|\/\s*100/);

    ['Pronunciation', 'Fluency', 'Timing'].forEach((term: string): void => {
      expect(within(figure).getByText(term).tagName).toBe('DT');
    });
  });

  test('the lines step names the studio actions and labels its sample as drawn', async (): Promise<void> => {
    const user = userEvent.setup();
    render(<App />);

    await user.click(tab(/Make every line yours/));
    const actions: HTMLElement = within(screen.getByRole('tabpanel')).getByRole('list', {
      name: 'Studio actions',
    });
    expect(
      within(actions)
        .getAllByRole('listitem')
        .map((item: HTMLElement): string => item.textContent?.trim() ?? ''),
    ).toEqual(['Listen', 'Record', 'Retry', 'Keep']);
    expect(screen.getByRole('tabpanel').textContent).toContain(WALKTHROUGH_LABEL);
  });
});
