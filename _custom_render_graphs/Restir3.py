from pathlib import WindowsPath, PosixPath
from falcor import *

def render_graph_Restir3():
    g = RenderGraph('Restir3')
    g.create_pass('VBufferRT', 'VBufferRT', {'outputSize': 'Default', 'samplePattern': 'Center', 'sampleCount': 16, 'useAlphaTest': True, 'adjustShadingNormals': True, 'forceCullMode': False, 'cull': 'Back', 'useTraceRayInline': False, 'useDOF': True})
    g.create_pass('RestirInitTemporal', 'RestirInitTemporal', {})
    g.create_pass('AccumulatePass', 'AccumulatePass', {'enabled': True, 'outputSize': 'Default', 'autoReset': True, 'precisionMode': 'Single', 'maxFrameCount': 0, 'overflowMode': 'Stop'})
    g.create_pass('ToneMapper', 'ToneMapper', {'outputSize': 'Default', 'useSceneMetadata': True, 'exposureCompensation': 0.0, 'autoExposure': False, 'filmSpeed': 100.0, 'whiteBalance': False, 'whitePoint': 6500.0, 'operator': 'Aces', 'clamp': True, 'whiteMaxLuminance': 1.0, 'whiteScale': 11.199999809265137, 'fNumber': 1.0, 'shutter': 1.0, 'exposureMode': 'AperturePriority'})
    g.add_edge('VBufferRT.vbuffer', 'RestirInitTemporal.vbuffer')
    g.add_edge('VBufferRT.viewW', 'RestirInitTemporal.viewW')
    g.add_edge('RestirInitTemporal.outputColor', 'AccumulatePass.input')
    g.add_edge('AccumulatePass.output', 'ToneMapper.src')
    g.add_edge('VBufferRT.mvec', 'RestirInitTemporal.motionVector')
    g.mark_output('ToneMapper.dst')
    return g

Restir3 = render_graph_Restir3()
try: m.addGraph(Restir3)
except NameError: None
