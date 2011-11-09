Node     = require('./nodes/node')
Text     = require('./nodes/text')
Haml     = require('./nodes/haml')
Code     = require('./nodes/code')
Comment  = require('./nodes/comment')
Filter   = require('./nodes/filter')

# The compiler class parses the source code and creates an syntax tree.
# In a second step the created tree can be rendered into a CoffeeScript
# template.
#
module.exports = class Compiler

  # Construct the HAML Coffee compiler.
  #
  # @param [Object] options the compiler options
  # @option options [Boolean] escape_haml whether to escape the output or not
  # @option options [String] format the template format, either `xhtml`, `html4` or `html5`
  #
  constructor: (@options = {}) ->
    @options.escape_html ?= true
    @options.format ?= 'html5'

  # Get the matching node type for the given expression. This
  # is also responsible for creating the nested tree structure,
  # since there is an exception for creating the node tree:
  # Within a filter expression, any empty line without indention
  # is added as child to the previous filter expression.
  #
  # @param [String] expression the HAML expression
  # @param [Node] previous_node the previously created node
  # @param [Node] parent_node the parent node
  # @param [Number] current_block_level the current HTML indention
  # @param [Number] current_code_block_level the current code indention
  # @return [Node] the parser node
  #
  node_factory: (expression, previous_node, parent_node, current_block_level, current_code_block_level) ->

    # Detect empty line within a filter
    if expression is '' && previous_node instanceof Filter
      top_filter_node = previous_node.getFilterExpressionNode()
      node = new Filter(top_filter_node, expression, current_block_level, current_code_block_level, @options.escape_html, @options.format)
      top_filter_node.addChild(node)

    # Detect filter expression node and nested childrens
    else if parent_node instanceof Filter || expression.match(/^:(escaped|preserve|css|javascript|plain|coffeescript)/)
      node = new Filter(parent_node, expression, current_block_level, current_code_block_level, @options.escape_html, @options.format)
      parent_node.addChild(node)

    # Detect comment node
    else if expression.match(/^(\/|-#)(.*)/)
      node = new Comment(parent_node, expression, current_block_level, current_code_block_level, @options.escape_html, @options.format)
      parent_node.addChild(node)

    # Detect code node
    else if expression.match(/^(-#|-|=|!=|\&=)\s*(.*)/)
      node = new Code(parent_node, expression, current_block_level, current_code_block_level, @options.escape_html)
      parent_node.addChild(node)

    # Detect Haml node
    else if expression.match(/^(%|#|\.|\!)(.*)/)
      node = new Haml(parent_node, expression, current_block_level, current_code_block_level, @options.escape_html, @options.format)
      parent_node.addChild(node)

    # Everything else is a text node
    else
      node = new Text(parent_node, expression, current_block_level, current_code_block_level)
      parent_node.addChild(node)

    node

  # Update the indention level for a code block.
  #
  # @param [Node] node the node to update
  #
  update_code_block_level: (node) ->
    if node instanceof Code
      @current_code_block_level = node.code_block_level + 1
    else
      @current_code_block_level = node.code_block_level

  # Test if the indention level has changed, either
  # increased or decreased.
  #
  # @return [Boolean] true when indention changed
  #
  indent_changed: ->
    @current_indent != @previous_indent

  # Test if the indention levels has been increased.
  #
  # @return [Boolean] true when increased
  #
  is_indent: ->
    @current_indent > @previous_indent

  # Calculate the indention size
  #
  update_tab_size: ->
     @tab_size = @current_indent - @previous_indent if @tab_size == 0

  # Update the current block level indention.
  #
  update_block_level: ->
    @current_block_level = @current_indent / @tab_size

    # Validate current indention
    if @current_block_level - Math.floor(@current_block_level) > 0
      throw("Indentation error in line #{ @line_number }")

    # Validate block level
    if (@current_indent - @previous_indent) / @tab_size > 1
      throw("Block level too deep in line #{ @line_number }")

    # Set the indention delta
    @delta = @previous_block_level - @current_block_level

  # Indention level has been increased:
  # Push the current parent node to the stack and make
  # the current node the parent node.
  #
  push_parent: ->
    @stack.push(@parent_node)
    @parent_node = @node

  # Indention level has been decreased:
  # Make the grand parent the current parent.
  #
  pop_parent: ->
    for i in [0..@delta-1]
      @parent_node = @stack.pop()

  # Parse the given source and create the nested node
  # structure. This parses the source code line be line, but
  # looks ahead to find lines that should be merged into the current line.
  # This is needed for splitting Haml attributes over several lines
  # and also for the different types of filters.
  #
  # Parsing does not create an output, it creates the syntax tree in the
  # compiler. To get the template, use `#render`.
  #
  # @param source [String] the HAML source code
  #
  parse: (source) ->
    # Initialize line and indent helpers
    @line_number = @previous_indent = @tab_size = @current_block_level = @previous_block_level = 0
    @current_code_block_level = @previous_code_block_level = 2

    # Initialize nodes
    @node = null
    @stack = []
    @root = @parent_node = new Node()

    # Keep lines for look ahead
    lines = source.split("\n")

    # Parse source line by line
    while (line = lines.shift()) isnt undefined

      # Get whitespace and Haml expressions
      result = line.match /^(\s*)(.*)/
      whitespace = result[1]
      expression = result[2]

      # Look ahead for more attributes
      while lines[0]?.match /([^:|\s|=]+\s*=>\s*(("[^"]+")|('[^']+')|[^\s,\}]+))|([\w]+=(("[^"]+")|('[^']+')|[^\s\)]+))/g
        attributes = lines.shift()
        expression += ' ' + attributes.match(/^(\s*)(.*)/)[2]
        @line_number++

      @current_indent = whitespace.length

      # Update indention levels and set the current parent
      if @indent_changed()
        @update_tab_size()
        @update_block_level()
        if @is_indent() then @push_parent() else @pop_parent()
        @update_code_block_level(@parent_node)

      # Create current node
      @node = @node_factory(expression, @node, @parent_node, @current_block_level, @current_code_block_level)

      # Save previous indention levels
      @previous_block_level = @current_block_level
      @previous_indent = @current_indent

      @line_number++

  # Render the parsed source code as CoffeeScript template.
  #
  # @param [String] filename the name to register the template
  # @param [String] namespace the namespace to register the template
  #
  render: (filename, namespace) ->
    namespace ?= 'HAML'
    output     = "window.#{ namespace } ?= {}\n"

    # Always include escape function in the template, since escaping
    # can be forced with `&=` event when turned off
    if @options.custom_html_escape
      escape_fn = @options.custom_html_escape
    else
      escape_fn = "window.#{ namespace }.html_escape"
      output +=
        escape_fn +
        '''
        ||= (text) ->
          "#{ text }"
          .replace(/&/g, '&amp;')
          .replace(/</g, '&lt;')
          .replace(/>/g, '&gt;')
          .replace(/\'/g, '&apos;')
          .replace(/\"/g, '&quot;')\n
        '''

    # Create parameter name from the filename, e.g. a file `users/new.hamlc`
    # will create window.HAML.user.new
    segments = filename.replace(/(\s|-)+/g, '_').split('/')
    name     = segments.pop()

    # Create code for file and namespace creation
    for segment in segments
      namespace += ".#{ segment }"
      output    += "window.#{ namespace } ?= {}\n"

    # Render the template
    output += "window.#{ namespace }.#{ name } = (context) ->\n"
    output += "  fn = (context) ->\n"
    output += "    o = []\n"
    output += "    e = #{ escape_fn }\n"
    output += @root.render()
    output += "    return o.join(\"\\n\")\n"
    output += "  return fn.call(context)\n"

    output
