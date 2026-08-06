import { render, screen } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import Home from './page';

describe('Home', () => {
  it('메인 헤딩을 렌더링한다', () => {
    render(<Home />);

    expect(
      screen.getByRole('heading', { name: /edit the page.tsx file/i }),
    ).not.toBeInTheDocument();
  });
});
