"""Replay may change transient screen state, never saved presentation metadata."""


def rejection(scenario, definition):
    state = scenario['state']
    if definition.mutable_presentation:
        return None
    if state.get('blockDisplays'):
        return 'Mermaid display switching saves page presentation and changes modification timestamps; replay is disabled.'
    views = {view['name']: view['type'] for view in getattr(definition, 'views', [])}
    view_name = state.get('databaseView')
    if view_name and view_name not in views:
        return 'Database view type is unknown; replay is blocked because timeline input must be excluded.'
    if views.get(view_name) == 'timeline':
        return 'Timeline display and panning can save the date preference and change modification timestamps; replay is disabled.'
    if any(scroll.get('scope') == 'database' for scroll in state.get('scrolls', [])) and not view_name:
        return 'Database scrolling requires an explicit view so timestamp-changing timeline input can be excluded.'
    return None
