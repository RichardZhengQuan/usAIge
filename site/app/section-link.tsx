"use client";

import type { ComponentPropsWithoutRef, MouseEvent } from "react";

type SectionLinkProps = Omit<ComponentPropsWithoutRef<"a">, "href"> & {
  targetId: string;
};

export function SectionLink({ targetId, onClick, ...props }: SectionLinkProps) {
  const handleClick = (event: MouseEvent<HTMLAnchorElement>) => {
    onClick?.(event);

    if (
      event.defaultPrevented ||
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    ) {
      return;
    }

    const target = document.getElementById(targetId);
    if (!target) return;

    event.preventDefault();
    window.history.replaceState(window.history.state, "", `#${targetId}`);
    target.scrollIntoView({ behavior: "auto", block: "start" });
  };

  return <a {...props} href={`#${targetId}`} onClick={handleClick} />;
}
