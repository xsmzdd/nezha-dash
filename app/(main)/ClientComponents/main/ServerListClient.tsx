"use client"

import { ArrowDownCircleIcon, ArrowUpCircleIcon } from "@heroicons/react/20/solid"
import Image from "next/image"
import { useTranslations } from "next-intl"
import { useFilter } from "@/app/context/network-filter-context"
import { useServerData } from "@/app/context/server-data-context"
import { useStatus } from "@/app/context/status-context"
import AnimateCountClient from "@/components/AnimatedCount"
import { Loader } from "@/components/loading/Loader"
import { Card, CardContent } from "@/components/ui/card"
import getEnv from "@/lib/env-entry"
import { cn, formatBytes } from "@/lib/utils"
import blogMan from "@/public/blog-man.webp"

export default function ServerOverviewClient() {
  const { data, error, isLoading } = useServerData()
  const { status, setStatus } = useStatus()
  const { filter, setFilter } = useFilter()
  const t = useTranslations("ServerOverviewClient")
  const disableCartoon = getEnv("NEXT_PUBLIC_DisableCartoon") === "true"

  const seaBlueRingClass =
    "ring-1 ring-white/10 transition-all hover:ring-[#5DADE2] dark:hover:ring-[#5DADE2]"

  if (error) {
    const errorInfo = error as any
    return (
      <div className="flex flex-col items-center justify-center">
        <p className="font-medium text-sm opacity-40">
          Error status:{errorInfo?.status} {errorInfo.info?.cause ?? errorInfo?.message}
        </p>
        <p className="font-medium text-sm opacity-40">{t("error_message")}</p>
      </div>
    )
  }

  return (
    <>
      <section className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Card
          onClick={() => {
            setFilter(false)
            setStatus("all")
          }}
          className={cn(seaBlueRingClass, "group cursor-pointer", {
            "border-transparent ring-2 ring-[#5DADE2] dark:ring-[#5DADE2]":
              status === "all" && filter === false,
          })}
        >
          <CardContent className="flex h-full items-center px-6 py-3">
            <section className="flex flex-col gap-1">
              <p className="font-medium text-sm md:text-base">{t("p_816-881_Totalservers")}</p>
              <div className="flex min-h-7 items-center gap-2">
                <span className="relative flex h-2 w-2">
                  <span className="relative inline-flex h-2 w-2 rounded-full bg-blue-500" />
                </span>
                {data?.result ? (
                  <div className="font-semibold text-lg">
                    <AnimateCountClient count={data?.result.length} />
                  </div>
                ) : (
                  <div className="flex h-7 items-center">
                    <Loader visible={true} />
                  </div>
                )}
              </div>
            </section>
          </CardContent>
        </Card>

        <Card
          onClick={() => {
            setFilter(false)
            setStatus("online")
          }}
          className={cn(seaBlueRingClass, "cursor-pointer", {
            "border-transparent ring-2 ring-[#5DADE2] dark:ring-[#5DADE2]":
              status === "online",
          })}
        >
          <CardContent className="flex h-full items-center px-6 py-3">
            <section className="flex flex-col gap-1">
              <p className="font-medium text-sm md:text-base">{t("p_1610-1676_Onlineservers")}</p>
              <div className="flex min-h-7 items-center gap-2">
                <span className="relative flex h-2 w-2">
                  <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-green-500 opacity-75" />
                  <span className="relative inline-flex h-2 w-2 rounded-full bg-green-500" />
                </span>
                {data?.result ? (
                  <div className="font-semibold text-lg">
                    <AnimateCountClient count={data?.live_servers} />
                  </div>
                ) : (
                  <div className="flex h-7 items-center">
                    <Loader visible={true} />
                  </div>
                )}
              </div>
            </section>
          </CardContent>
        </Card>

        <Card
          onClick={() => {
            setFilter(false)
            setStatus("offline")
          }}
          className={cn(seaBlueRingClass, "cursor-pointer", {
            "border-transparent ring-2 ring-[#5DADE2] dark:ring-[#5DADE2]":
              status === "offline",
          })}
        >
          <CardContent className="flex h-full items-center px-6 py-3">
            <section className="flex flex-col gap-1">
              <p className="font-medium text-sm md:text-base">
                {t("p_2532-2599_Offlineservers")}
              </p>
              <div className="flex min-h-7 items-center gap-2">
                <span className="relative flex h-2 w-2">
                  <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-500 opacity-75" />
                  <span className="relative inline-flex h-2 w-2 rounded-full bg-red-500" />
                </span>
                {data?.result ? (
                  <div className="font-semibold text-lg">
                    <AnimateCountClient count={data?.offline_servers} />
                  </div>
                ) : (
                  <div className="flex h-7 items-center">
                    <Loader visible={true} />
                  </div>
                )}
              </div>
            </section>
          </CardContent>
        </Card>

        <Card
          onClick={() => {
            setStatus("all")
            setFilter(true)
          }}
          className={cn(seaBlueRingClass, "group cursor-pointer", {
            "border-transparent ring-2 ring-[#5DADE2] dark:ring-[#5DADE2]": filter === true,
          })}
        >
          <CardContent className="relative flex h-full items-center px-6 py-3">
            <section className="flex w-full flex-col gap-1">
              <div className="flex w-full items-center justify-between">
                <p className="font-medium text-sm md:text-base">{t("network")}</p>
              </div>
              {data?.result ? (
                <>
                  <section className="flex flex-row flex-wrap items-start gap-1 pr-0">
                    <p className="text-nowrap font-medium text-[12px] text-blue-800 dark:text-blue-400">
                      ↑{formatBytes(data?.total_out_bandwidth)}
                    </p>
                    <p className="text-nowrap font-medium text-[12px] text-purple-800 dark:text-purple-400">
                      ↓{formatBytes(data?.total_in_bandwidth)}
                    </p>
                  </section>
                  <section className="-mr-1 flex flex-row flex-wrap items-start gap-1 sm:items-center">
                    <p className="flex items-center text-nowrap font-semibold text-[11px]">
                      <ArrowUpCircleIcon className="mr-0.5 size-3 sm:mb-px" />
                      {formatBytes(data?.total_out_speed)}/s
                    </p>
                    <p className="flex items-center text-nowrap font-semibold text-[11px]">
                      <ArrowDownCircleIcon className="mr-0.5 size-3" />
                      {formatBytes(data?.total_in_speed)}/s
                    </p>
                  </section>
                </>
              ) : (
                <div className="flex h-[38px] items-center">
                  <Loader visible={true} />
                </div>
              )}
            </section>

            {!disableCartoon && (
              <Image
                className="absolute top-[-85px] right-3 z-50 w-20 scale-90 transition-all group-hover:opacity-50 md:scale-100"
                alt={"Hamster1963"}
                src={blogMan}
                priority
                placeholder="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAL0AAAFACAMAAADeco1xAAABvFBMVEUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAQEAAAAAAAAAAAAAAAAAAAANDQ2rq6sAAAD////7+/sEBAQPDw/09PT5+fnx8fETExMJCQkMDAzp6enk5ORzc3Nubm6ioqIsLCwxMTHs7Ozf39/T09NHR0cGBgba2to1NTUaGRrHx8eEhIQdHR3m5uZBQUEgICD29vawsLCqqqp9fX0XFxfAwMCfn5+ZmZnc3NzDw8OPj49cXFwoKCjQ0NAiIiIVFRWWlpaJiYnh4eG2traBgYElJSW4uLimpqY9PT05OTnX19ezs7N5eXlWVlZTU1NLS0tERES9vb2MjIx3d3fV1dXJycmtra2cnJxgYGBZWVljY2P4+Pi6urqTk5NpaWlQUFBmZmZNTU3Ozc7u7u5ra2vLy8u8vLwMo0bGAAAAPXRSTlMA/O1tjfHitZIKBKQH+vf0DugqnpgRPRjDx0ZCMd7TvrF0h2cuHH03JCAVzGDZW1PKuldPStCteSepgfXpPpiFWAAAFtdJREFUeNrU3PdTGlsUB/CLii2xRqOJsaQYX0x/qe/NfM/SQZoCgtiwYg22KL6oacaoMSam/MMPUHGFXYFkdyGfcRzlB+e4c8+5555lYTngzu3njKeU/RHqrsQCvViO+lt3CoqvNtw6d4WxR0+eXr3Fct/liqaa6uoL5YBKjSg1Wu4UVAC4+7i9lUW0n2e5qvWcClCrIagqr6WguKiqvpLlphsPkYa/Wa4p+edZ9d9F5UiHuiDXFk9pC8qRtmssx1xHBsrv5xewHNKQh8yU5VAFbahCpor+YjkivxyZy3uWE8l7vgC/5lJ+Wy3LsvYW/LrCqyx7Ll+vu3Ibv+MRy5565FXgd5RdZ9nzAL9Lla2+obQh/y5+m/oKy4p8SOJJdnrOZkijmGXBvXJIo+wiU9wzFaRyiSms/RwkVKBoz9PedgmSalSwYyitV0FaT5mC6iGxvDammNpGSK1QubpTA+lVPGbKaIMcChVK3ALIQaFGv64KcrjJFHEf8rjDROVea5kkT5ENtxgyuatAp1/6AHI5x2RXl4cjf2L0tVXg+ePKThHkUsBkd74eR/7E6J+XQS75TMifkrVifWaud5gxqvtMfg2QS1MJE/YHdAoRbUx2DyGbeyyR4tF7AGiRqz3+vTKIcIyvOKZ+ul59frm67bTavzq9yMy/THZX8iBii1zjm3SIi319sC3u59Z21QwRxsUwsKSnQ6GB6bVlIhrc2ltYtr7IlXnsHRXEmLw7ATryzqQBHG/o0E8t0nC7ksmuRnTZd9EJrqu7J9RvHqdD1lxZOucgyLRKyX72H139/5COvGoms/ONENRr4CzEp+8iIt17ihlFWqpambzON0GQl6wjQ8QzZ/ZTXABpyWtn8sqHsK/cAJx6OrGNMMXZkZYaJrO2FhWE7JATTo5O2DCtp2N7ubFwGDtfCCFWmvO8JZ4FODg6ZsuZk20LhPhJ/54jHv3iB4rrRxqaS5j82tQQMEkx77tIwIQnR3pMxkoKIWCcIvQ2Y4AEDCMdLUwB1SoIsFPEGIbo16N/whTQqhaNfm2FIgzJ0efOewULxK+9bVpPHVMDfZQgnCtnK7FGZ4wiXNrwlBFfky6+F2loqmMKqHx0AclCFDXaP7sxxFEiN1LLu8EUUi9U7w/pKZnBkSPjnEMNZQKdgrjF3JgDxl1CoulBEuVHKuWKBC/eLWh6iGgoQFFjnxJWjhNnu3SRKUkgbxejS0QzxpHej14dnbKTC5X+xDMk8XJElml4t53AMEd8XD/O1swU1aZCIs0mEQX3AcyG6LQ+Y/ZvWfGVFiHJd4pyLUwYKEGXOcee5njeiETGeRLRYcSZikqYwv4qRCIbidDN4gyNDeeZ4v5BItMEiXh9VvDVLAsakGSpiyiz/r"
              />
            )}
          </CardContent>
        </Card>
      </section>

      {data?.result === undefined && !isLoading && (
        <div className="flex flex-col items-center justify-center">
          <p className="font-medium text-sm opacity-40">{t("error_message")}</p>
        </div>
      )}
    </>
  )
}
