"use client"

import { useLocale, useTranslations } from "next-intl"
import { createRef, useEffect, useRef, useState } from "react"
import getEnv from "@/lib/env-entry"
import { cn } from "@/lib/utils"

export default function Switch({
  allTag,
  nowTag,
  tagCountMap,
  onTagChange,
}: {
  allTag: string[]
  nowTag: string
  tagCountMap: Record<string, number>
  onTagChange: (tag: string) => void
}) {
  const scrollRef = useRef<HTMLDivElement>(null)
  const tagRefs = useRef(allTag.map(() => createRef<HTMLDivElement>()))
  const t = useTranslations("ServerListClient")
  const locale = useLocale()
  const [indicator, setIndicator] = useState<{ x: number; w: number } | null>(null)
  const [isFirstRender, setIsFirstRender] = useState(true)

  useEffect(() => {
    const savedTag = sessionStorage.getItem("selectedTag")
    if (savedTag && allTag.includes(savedTag)) {
      onTagChange(savedTag)
    }
  }, [allTag, onTagChange])

  useEffect(() => {
    const container = scrollRef.current
    if (!container) return

    const isOverflowing = container.scrollWidth > container.clientWidth
    if (!isOverflowing) return

    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      container.scrollLeft += e.deltaY
    }

    container.addEventListener("wheel", onWheel, { passive: false })

    return () => {
      container.removeEventListener("wheel", onWheel)
    }
  }, [])

  useEffect(() => {
    const currentTagElement = tagRefs.current[allTag.indexOf(nowTag)]?.current
    if (currentTagElement) {
      setIndicator({
        x: currentTagElement.offsetLeft,
        w: currentTagElement.offsetWidth,
      })
    }

    if (isFirstRender) {
      setTimeout(() => {
        setIsFirstRender(false)
      }, 50)
    }
  }, [nowTag, locale, allTag, isFirstRender])

  useEffect(() => {
    const currentTagElement = tagRefs.current[allTag.indexOf(nowTag)]?.current
    const container = scrollRef.current

    if (currentTagElement && container) {
      const containerRect = container.getBoundingClientRect()
      const tagRect = currentTagElement.getBoundingClientRect()

      const scrollLeft = currentTagElement.offsetLeft - (containerRect.width - tagRect.width) / 2

      container.scrollTo({
        left: Math.max(0, scrollLeft),
        behavior: "smooth",
      })
    }
  }, [nowTag, locale])

  return (
    <div
      ref={scrollRef}
      className="scrollbar-hidden z-50 flex flex-col items-start overflow-x-scroll rounded-[50px]"
    >
      <div className="relative flex items-center gap-1 overflow-hidden rounded-[50px] border border-white/12 bg-white/10 p-[3px] shadow-[0_10px_30px_rgba(0,0,0,0.18)] backdrop-blur-2xl supports-[backdrop-filter]:bg-white/8">
        <div className="pointer-events-none absolute inset-0 rounded-[50px] bg-gradient-to-b from-white/18 via-white/8 to-transparent" />
        <div className="pointer-events-none absolute inset-0 rounded-[50px] shadow-[inset_0_1px_0_rgba(255,255,255,0.22),inset_0_-1px_0_rgba(255,255,255,0.05)]" />

        {indicator && (
          <div
            className="absolute top-[3px] left-0 z-10 h-[35px] border border-[#F7C35A]/70 bg-[#F3A402]/88 shadow-[0_8px_22px_rgba(0,0,0,0.16),inset_0_1px_0_rgba(255,255,255,0.32)] backdrop-blur-md"
            style={{
              borderRadius: 24,
              width: `${indicator.w}px`,
              transform: `translateX(${indicator.x}px)`,
              transition: isFirstRender ? "none" : "all 0.5s cubic-bezier(0.4, 0, 0.2, 1)",
            }}
          />
        )}

        {allTag.map((tag, index) => {
          const isActive = nowTag === tag

          return (
            <div
              key={tag}
              ref={tagRefs.current[index]}
              onClick={() => {
                onTagChange(tag)
                sessionStorage.setItem("selectedTag", tag)
              }}
              className={cn(
                "relative cursor-pointer rounded-3xl px-2.5 py-[8px] font-semibold text-[13px] transition-all duration-500 ease-in-out",
                isActive ? "text-[#6E4900]" : "text-white/82 hover:text-white",
              )}
            >
              <div className="relative z-20 flex items-center gap-1">
                <div className="flex items-center gap-2 whitespace-nowrap">
                  {tag === "defaultTag" ? t("defaultTag") : tag}
                  {getEnv("NEXT_PUBLIC_ShowTagCount") === "true" && tag !== "defaultTag" && (
                    <div
                      className={cn(
                        "w-fit rounded-full px-1.5 text-[12px] transition-all",
                        isActive
                          ? "bg-[#6E4900]/10 text-[#6E4900]"
                          : "bg-white/12 text-white/88",
                      )}
                    >
                      {tagCountMap[tag]}
                    </div>
                  )}
                </div>
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
