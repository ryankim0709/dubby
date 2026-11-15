import { cleanup, render } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import axe from 'axe-core';
import { afterEach, expect, test } from 'vitest';
import App from './App';

afterEach(cleanup);

const violations = async (container: HTMLElement): Promise<string[]> => {
  const results: axe.AxeResults = await axe.run(container, {
    runOnly: {
      type: 'tag',
      values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa', 'best-practice'],
    },
    rules: { 'color-contrast': { enabled: false } },
  });
  return results.violations.map(
    (violation: axe.Result): string =>
      `${violation.id}: ${violation.nodes.map((node: axe.NodeResult): string => node.target.join(' ')).join(' | ')}`,
  );
};

test('the page has no axe violations in any walkthrough step', async (): Promise<void> => {
  const user = userEvent.setup();
  const { container } = render(<App />);

  expect(await violations(container)).toEqual([]);

  for (const tab of Array.from(container.querySelectorAll<HTMLElement>('[role="tab"]'))) {
    await user.click(tab);
    expect(await violations(container), tab.id).toEqual([]);
  }
});
