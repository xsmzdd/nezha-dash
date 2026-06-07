"use client";

import { useLocale, useTranslations } from "next-intl";
import { createRef, useCallback, useEffect, useRef, useState } from "react";
import getEnv from "@/lib/env-entry";
import { cn } from "@/lib/utils";

export default function Switch({
  allTag,
  nowTag,
  tagCountMap,
  onTagChange,
}: {
  allTag: string[];
  nowTag: string;
  tagCountMap: Record<string, number>;
  onTagChange: (tag: string) => void;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const tagRefs = useRef(allTag.map(() => createRef<HTMLDivElement>()));
  const t = useTranslations("ServerListClient");
  const locale = useLocale();
  const [indicator, setIndicator] = useState<{ x: number; w: number } | null>(
    null,
  );
  const [isFirstRender, setIsFirstRender] = useState(true);

  tagRefs.current = allTag.map(
    (_, index) => tagRefs.current[index] ?? createRef<HTMLDivElement>(),
  );

  const moveIndicatorToTag = useCallback(
    (tagValue: string) => {
      const currentTagElement =
        tagRefs.current[allTag.indexOf(tagValue)]?.current;

      if (!currentTagElement) {
        setIndicator(null);
        return;
      }

      setIndicator({
        x: currentTagElement.offsetLeft,
        w: currentTagElement.offsetWidth,
      });
    },
    [allTag],
  );

  useEffect(() => {
    const savedTag = sessionStorage.getItem("selectedTag");
    if (savedTag && allTag.includes(savedTag)) {
      onTagChange(savedTag);
    }
  }, [allTag, onTagChange]);

  useEffect(() => {
    const container = scrollRef.current;
    if (!container) return;

    const isOverflowing = container.scrollWidth > container.clientWidth;
    if (!isOverflowing) return;

    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      container.scrollLeft += e.deltaY;
    };

    container.addEventListener("wheel", onWheel, { passive: false });

    return () => {
      container.removeEventListener("wheel", onWheel);
    };
  }, []);

  useEffect(() => {
    moveIndicatorToTag(nowTag);

    if (isFirstRender) {
      setTimeout(() => {
        setIsFirstRender(false);
      }, 50);
    }
  }, [nowTag, locale, allTag, isFirstRender, moveIndicatorToTag]);

  useEffect(() => {
    const currentTagElement = tagRefs.current[allTag.indexOf(nowTag)]?.current;
    const container = scrollRef.current;

    if (currentTagElement && container) {
      const containerRect = container.getBoundingClientRect();
      const tagRect = currentTagElement.getBoundingClientRect();

      const scrollLeft =
        currentTagElement.offsetLeft -
        (containerRect.width - tagRect.width) / 2;

      container.scrollTo({
        left: Math.max(0, scrollLeft),
        behavior: "smooth",
      });
    }
  }, [nowTag, locale]);

  return (
    <div
      ref={scrollRef}
      className="scrollbar-hidden z-50 flex flex-col items-start overflow-x-scroll rounded-[50px]"
    >
      <div
        className="relative flex items-center gap-1 overflow-hidden rounded-[50px] border border-white/12 bg-white/5 p-[3px] shadow-[0_10px_30px_rgba(0,0,0,0.12)] backdrop-blur-md supports-[backdrop-filter]:bg-white/4"
        onMouseLeave={() => moveIndicatorToTag(nowTag)}
      >
        <div className="pointer-events-none absolute inset-0 rounded-[50px] bg-gradient-to-b from-white/10 via-white/4 to-transparent" />
        <div className="pointer-events-none absolute inset-0 rounded-[50px] shadow-[inset_0_1px_0_rgba(255,255,255,0.22),inset_0_-1px_0_rgba(255,255,255,0.05)]" />

        {indicator && (
          <div
            className="absolute top-[3px] left-0 z-10 h-[35px] border border-[#8FA38F] bg-[#718771]/70 shadow-[0_8px_22px_rgba(0,0,0,0.12),inset_0_1px_0_rgba(255,255,255,0.16)] backdrop-blur-sm"
            style={{
              borderRadius: 24,
              width: `${indicator.w}px`,
              transform: `translateX(${indicator.x}px)`,
              transition: isFirstRender
                ? "none"
                : "all 0.5s cubic-bezier(0.4, 0, 0.2, 1)",
            }}
          />
        )}

        {allTag.map((tag, index) => {
          const isActive = nowTag === tag;

          return (
            <div
              key={tag}
              ref={tagRefs.current[index]}
              onMouseEnter={() => moveIndicatorToTag(tag)}
              onFocus={() => moveIndicatorToTag(tag)}
              onClick={() => {
                onTagChange(tag);
                sessionStorage.setItem("selectedTag", tag);
                moveIndicatorToTag(tag);
              }}
              className={cn(
                "relative cursor-pointer rounded-3xl px-2.5 py-[8px] font-semibold text-[13px] transition-all duration-500 ease-in-out",
                isActive ? "text-[#F5F5F0]" : "text-white/82 hover:text-white",
              )}
            >
              <div className="relative z-20 flex items-center gap-1">
                <div className="flex items-center gap-2 whitespace-nowrap">
                  {tag === "defaultTag" ? t("defaultTag") : tag}
                  {getEnv("NEXT_PUBLIC_ShowTagCount") === "true" &&
                    tag !== "defaultTag" && (
                      <div
                        className={cn(
                          "w-fit rounded-full px-1.5 text-[12px] transition-all",
                          isActive
                            ? "bg-[#F5F5F0]/15 text-[#F5F5F0]"
                            : "bg-white/12 text-white/88",
                        )}
                      >
                        {tagCountMap[tag]}
                      </div>
                    )}
                </div>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
