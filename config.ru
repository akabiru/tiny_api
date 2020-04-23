# frozen_string_literal: true

app =
  proc do |env|
    qs = env['QUERY_STRING']
    number = Integer(qs.match(/number=(\d+)/)[1])

    [
      '200',
      { 'Content-Type' => 'text/plain' },
      [number.even? ? 'even' : 'odd']
    ]
  end

run app
