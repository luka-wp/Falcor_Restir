import json
import matplotlib.pyplot as plt
from matplotlib.figure import Figure
from matplotlib.axes import Axes
from matplotlib.ticker import FormatStrFormatter
import sys
import os

events_key = "events"
frame_count_key = "frame_count"
records_key = "records"
stats_key = "stats"
min_key = "min"
max_key = "max"

pathtracer_keys: list[str] = [
    # 1
    "/onFrameRender/RenderGraphExe::execute()/MinimalPathTracer/cpu_time",
    # 2
    "/onFrameRender/RenderGraphExe::execute()/MinimalPathTracer/gpu_time",
    # 3
    "/onFrameRender/RenderGraphExe::execute()"
    "/MinimalPathTracer/raytraceScene/cpu_time",
    # 4
    "/onFrameRender/RenderGraphExe::execute()"
    "/MinimalPathTracer/raytraceScene/gpu_time"
]

restir_keys: list[str] = [
    # 1
    "/onFrameRender/RenderGraphExe::execute()/RestirInitTemporal/cpu_time",
    # 2
    "/onFrameRender/RenderGraphExe::execute()/RestirInitTemporal/gpu_time",
    # 3
    "/onFrameRender/RenderGraphExe::execute()"  # New line
    "/RestirInitTemporal/raytraceScene/cpu_time",
    # 4
    "/onFrameRender/RenderGraphExe::execute()"  # New line
    "/RestirInitTemporal/raytraceScene/gpu_time"
]


class DataSet:
    frames: int
    min: float
    max: float
    records: list[float]


def prepare_plot() -> tuple[Figure, Axes]:
    (fig, ax) = plt.subplots(1, 1)
    ax.grid(True)
    ax.set_xlabel("Frame")
    ax.set_ylabel("Time [ms]")
    ax.yaxis.set_major_formatter(FormatStrFormatter("%.2f"))
    return (fig, ax)


def create_plot(x_axes: list[list], y_axes: list[list], labels: list[str],
                colors: list[str], title: str):

    if len(x_axes) != len(y_axes) \
            or len(x_axes) != len(labels) \
            or len(x_axes) != len(colors):
        print("Not equal num of entries")
        return

    (fig, ax) = prepare_plot()
    ax.set_title(title)

    num = len(x_axes)
    for i in range(num):
        x_axis = x_axes[i]
        y_axis = y_axes[i]
        label = labels[i]
        color = colors[i]
        ax.plot(x_axis, y_axis, color=color,
                label=label, linestyle="-", marker=" ")

    ax.legend()

    plt.show()

    return (fig, ax)


def parse_file(file_path: str, event_type_keys: list[str]) -> list[DataSet]:
    # CPU, GPU, RayTrace CPU, RayTrace GPU
    with open(file_path) as file:
        data = json.load(file)
    data_sets = []
    frames = data[frame_count_key]
    events = data[events_key]
    for event_type_key in event_type_keys:
        event = events[event_type_key]
        data_set = DataSet()
        data_set.frames = frames
        data_set.min = event[stats_key][min_key]
        data_set.min = event[stats_key][max_key]
        data_set.records = event[records_key]
        data_sets.append(data_set)
    return data_sets


def plot_data_sets(data_sets: tuple[DataSet, DataSet], num_frames: int):
    frames = min(data_sets[0].frames, data_sets[1].frames)
    frames = min(frames, num_frames) if num_frames > 0 else frames

    blue_offset = data_sets[0].frames - frames
    orange_offset = data_sets[1].frames - frames

    x_axis = [i + 1 for i in range(frames)]
    blue_data = data_sets[0].records[blue_offset:]
    orange_data = data_sets[1].records[orange_offset:]

    (fig, ax) = prepare_plot()
    ax.plot(x_axis, blue_data, label='Path Tracer',
            color='blue', linestyle='-', marker=' ')
    ax.plot(x_axis, orange_data, label='ReSTIR',
            color='orange', linestyle='-', marker=' ')
    ax.legend()
    return (fig, ax)


def plot_files(pathtracer_file: str, restir_file: str,
               num_frames: int, subfolder: str):
    pt_sets = parse_file(pathtracer_file, pathtracer_keys)
    re_sets = parse_file(restir_file, restir_keys)
    if(len(pt_sets) != len(re_sets)):
        print("Data sets size miss match")
        return

    titles = [
        "CPU Time",
        "GPU Time",
        "Ray Trace CPU Time",
        "Ray Trace GPU Time"
    ]

    for i in range(len(pt_sets)):
        (fig, ax) = plot_data_sets((pt_sets[i], re_sets[i]), num_frames)
        ax.set_title(titles[i])
        file_name = "_".join(titles[i].split(" "))
        path = subfolder + "/" + file_name + ".png"
        fig.savefig(path)


def main():
    num_args = len(sys.argv)
    if num_args < 4:  # 1 source command, 2 files, 1 subfolder, 1 frames value
        print("Args: <pt_file> <re_file> <subfolder> <optional_num_frames>")
        return

    pt_file = sys.argv[1]
    re_file = sys.argv[2]

    num_frames = -1
    if num_args == 5:
        num_frames = int(sys.argv[4])

    subfolder = "./" + sys.argv[3]
    if not os.path.exists(subfolder):
        os.mkdir(subfolder)

    # num_frames = -1
    # subfolder = "./" + "plots"
    # pt_file = "./minpt_static_1d_4p_1.json"
    # re_file = "./restir_static_1d_4p_1.json"

    plot_files(pt_file, re_file, num_frames, subfolder)


if __name__ == "__main__":
    main()
