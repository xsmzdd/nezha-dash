"use client"

import { geoNaturalEarth1, geoPath } from "d3-geo"
import { type PointerEvent, type WheelEvent, useEffect, useMemo, useRef, useState } from "react"
import MapTooltip from "@/app/(main)/ClientComponents/main/MapTooltip"
import { useTooltip } from "@/app/context/tooltip-context"
import { countryCoordinates } from "@/lib/geo/geo-limit"
import { cn, getCountryCodeForMap } from "@/lib/utils"

interface InteractiveMapProps {
  countries: string[]
  serverCounts: { [key: string]: number }
  width: number
  height: number
  filteredFeatures: any[]
  nezhaServerList: any
}

export function InteractiveMap({
  countries,
  serverCounts,
  width,
  height,
  filteredFeatures,
  nezhaServerList,
}: InteractiveMapProps) {
  const { setTooltipData } = useTooltip()
  const [zoom, setZoom] = useState(1)
  const [pan, setPan] = useState({ x: 0, y: 0 })
  const [dragStart, setDragStart] = useState<{ clientX: number; clientY: number; panX: number; panY: number } | null>(null)
  const svgRef = useRef<SVGSVGElement>(null)

  const padX = 24
  const padY = 34
  const capsuleX = padX
  const capsuleY = padY
  const capsuleWidth = width - padX * 2
  const capsuleHeight = height - padY * 2
  const capsuleRadius = capsuleHeight / 2

  const projection = geoNaturalEarth1()
    .scale(width / 5.55)
    .translate([width / 2, height / 2 + 8])

  const path = geoPath().projection(projection)
  const zoomTransform = `translate(${pan.x} ${pan.y}) translate(${width / 2} ${height / 2}) scale(${zoom}) translate(${-width / 2} ${-height / 2})`

  const capsulePath = `
    M ${capsuleX + capsuleRadius} ${capsuleY}
    H ${capsuleX + capsuleWidth - capsuleRadius}
    A ${capsuleRadius} ${capsuleRadius} 0 0 1 ${capsuleX + capsuleWidth - capsuleRadius} ${capsuleY + capsuleHeight}
    H ${capsuleX + capsuleRadius}
    A ${capsuleRadius} ${capsuleRadius} 0 0 1 ${capsuleX + capsuleRadius} ${capsuleY}
    Z
  `

  const isInsideCapsule = (x: number, y: number) => {
    const leftCenterX = capsuleX + capsuleRadius
    const rightCenterX = capsuleX + capsuleWidth - capsuleRadius
    const centerY = capsuleY + capsuleHeight / 2
    const r = capsuleRadius

    if (y < capsuleY || y > capsuleY + capsuleHeight) return false

    if (x >= leftCenterX && x <= rightCenterX) return true

    const dxLeft = x - leftCenterX
    const dyLeft = y - centerY
    if (x < leftCenterX && dxLeft * dxLeft + dyLeft * dyLeft <= r * r) return true

    const dxRight = x - rightCenterX
    const dyRight = y - centerY
    if (x > rightCenterX && dxRight * dxRight + dyRight * dyRight <= r * r) return true

    return false
  }

  const getZoomedPoint = (point: [number, number]): [number, number] => [
    pan.x + width / 2 + (point[0] - width / 2) * zoom,
    pan.y + height / 2 + (point[1] - height / 2) * zoom,
  ]

  const getCountryServers = (countryCode: string) =>
    nezhaServerList.result
      .filter((server: any) => {
        const serverCountryCode = getCountryCodeForMap(server.host.CountryCode)
        return serverCountryCode === countryCode
      })
      .map((server: any) => ({
        id: server.id,
        name: server.name,
        status: server.online_status,
      }))

  const countrySet = useMemo(() => new Set(countries), [countries])

  useEffect(() => {
    const svg = svgRef.current
    if (!svg) return

    const preventPageScroll = (event: globalThis.WheelEvent) => {
      event.preventDefault()
    }

    svg.addEventListener("wheel", preventPageScroll, { passive: false })

    return () => {
      svg.removeEventListener("wheel", preventPageScroll)
    }
  }, [])

  const handleWheelZoom = (event: WheelEvent<SVGSVGElement>) => {
    event.preventDefault()
    event.stopPropagation()
    setTooltipData(null)

    const svg = event.currentTarget
    const rect = svg.getBoundingClientRect()
    const point = {
      x: ((event.clientX - rect.left) / rect.width) * width,
      y: ((event.clientY - rect.top) / rect.height) * height,
    }

    const nextZoom = Math.min(3, Math.max(0.8, Number((zoom * (event.deltaY < 0 ? 1.15 : 0.87)).toFixed(3))))
    const worldPoint = {
      x: (point.x - pan.x - width / 2) / zoom + width / 2,
      y: (point.y - pan.y - height / 2) / zoom + height / 2,
    }

    setZoom(nextZoom)
    setPan({
      x: point.x - width / 2 - (worldPoint.x - width / 2) * nextZoom,
      y: point.y - height / 2 - (worldPoint.y - height / 2) * nextZoom,
    })
  }

  const handlePointerDown = (event: PointerEvent<SVGSVGElement>) => {
    event.currentTarget.setPointerCapture(event.pointerId)
    setTooltipData(null)
    setDragStart({ clientX: event.clientX, clientY: event.clientY, panX: pan.x, panY: pan.y })
  }

  const handlePointerMove = (event: PointerEvent<SVGSVGElement>) => {
    if (!dragStart) return

    const rect = event.currentTarget.getBoundingClientRect()
    const dx = ((event.clientX - dragStart.clientX) / rect.width) * width
    const dy = ((event.clientY - dragStart.clientY) / rect.height) * height

    setTooltipData(null)
    setPan({ x: dragStart.panX + dx, y: dragStart.panY + dy })
  }

  const handlePointerUp = (event: PointerEvent<SVGSVGElement>) => {
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    setDragStart(null)
  }

  return (
    <div className="relative aspect-2/1 w-full" onMouseLeave={() => setTooltipData(null)}>
      <svg
        ref={svgRef}
        width={width}
        height={height}
        viewBox={`0 0 ${width} ${height}`}
        xmlns="http://www.w3.org/2000/svg"
        className={cn("h-auto w-full touch-none", dragStart ? "cursor-grabbing" : "cursor-grab")}
        onWheel={handleWheelZoom}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
        onPointerCancel={handlePointerUp}
      >
        <title>Interactive Map</title>

        <defs>
          <clipPath id="world-capsule-clip">
            <path d={capsulePath} />
          </clipPath>

          <linearGradient id="ocean-base-gradient" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stopColor="rgba(214, 230, 224, 0.42)" />
            <stop offset="50%" stopColor="rgba(151, 184, 180, 0.36)" />
            <stop offset="100%" stopColor="rgba(111, 151, 158, 0.42)" />
          </linearGradient>

          <radialGradient id="ocean-soft-light" cx="50%" cy="45%" r="75%">
            <stop offset="0%" stopColor="rgba(255,255,255,0.26)" />
            <stop offset="100%" stopColor="rgba(255,255,255,0.00)" />
          </radialGradient>
        </defs>

        <g clipPath="url(#world-capsule-clip)">
          <rect x="0" y="0" width={width} height={height} fill="url(#ocean-base-gradient)" />
          <rect x="0" y="0" width={width} height={height} fill="url(#ocean-soft-light)" />

          <rect
            x="0"
            y="0"
            width={width}
            height={height}
            fill="transparent"
            onMouseEnter={() => setTooltipData(null)}
          />

          <g transform={zoomTransform}>
            {filteredFeatures.map((feature, index) => {
              const countryCode = feature.properties.iso_a2_eh
              const isHighlighted = countrySet.has(countryCode)
              const serverCount = serverCounts[countryCode] || 0

              return (
                <path
                  key={countryCode + String(index)}
                  d={path(feature) || ""}
                  className={
                    isHighlighted
                      ? "cursor-pointer fill-[#C9883A] stroke-[0.45] stroke-[#9F6C31] transition-all hover:fill-[#D99A4A] dark:fill-[#C9883A] dark:hover:fill-[#D99A4A]"
                      : "cursor-pointer fill-[#D9C38C] stroke-[0.45] stroke-[#BFA873] transition-all hover:fill-[#E5D3A7] dark:fill-[#A79566] dark:stroke-[#7E704D] dark:hover:fill-[#B9A873]"
                  }
                  onMouseEnter={() => {
                    const centroid = path.centroid(feature)
                    if (!centroid || Number.isNaN(centroid[0]) || Number.isNaN(centroid[1])) {
                      return
                    }

                    if (!isInsideCapsule(centroid[0], centroid[1])) {
                      return
                    }

                    setTooltipData({
                      centroid: getZoomedPoint(centroid as [number, number]),
                      country: feature.properties.name_zh || feature.properties.name,
                      count: serverCount,
                      servers: isHighlighted ? getCountryServers(countryCode) : [],
                    })
                  }}
                />
              )
            })}

            {countries.map((countryCode) => {
              const isInFilteredFeatures = filteredFeatures.some(
                (feature) => feature.properties.iso_a2_eh === countryCode,
              )

              if (isInFilteredFeatures) return null

              const coords = countryCoordinates[countryCode]
              if (!coords) return null

              const projected = projection([coords.lng, coords.lat])
              if (!projected) return null

              const [x, y] = projected
              const serverCount = serverCounts[countryCode] || 0

              if (!isInsideCapsule(x, y)) return null

              return (
                <g
                  key={countryCode}
                  onMouseEnter={() => {
                    setTooltipData({
                      centroid: getZoomedPoint([x, y]),
                      country: coords.name,
                      count: serverCount,
                      servers: getCountryServers(countryCode),
                    })
                  }}
                  className="cursor-pointer"
                >
                  <circle
                    cx={x}
                    cy={y}
                    r={4}
                    className="fill-[#C9883A] stroke-white transition-all hover:fill-[#D99A4A] dark:fill-[#C9883A] dark:hover:fill-[#D99A4A]"
                  />
                </g>
              )
            })}
          </g>
        </g>
      </svg>

      <MapTooltip />
    </div>
  )
}
